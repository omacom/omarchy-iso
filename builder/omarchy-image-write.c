/*
 * omarchy-image-write: put the root image on the install target at the speed
 * of the drive.
 *
 * `zstdcat image.zst | dd oflag=direct` is one thread that decodes, copies
 * and writes in turn, so the drive sees one request at a time and sits idle
 * while zstd works. Here the image is a sequence of independent zstd frames of
 * FRAME_SIZE bytes each, followed by a seek table listing every frame's
 * compressed and decompressed size (zstd's seekable format, as in the zstd
 * tree's contrib/seekable_format). From the table alone the target offset of
 * every frame is known before anything is decoded, and N threads can each
 * take the next frame, decode it into their own buffer and pwrite() it with
 * O_DIRECT. The seek table sits in a skippable frame, so the file stays an
 * ordinary .zst: `zstd -d` reads it unchanged.
 *
 *   omarchy-image-write pack  RAW IMAGE.zst
 *   omarchy-image-write write IMAGE.zst TARGET [THREADS]
 *
 * write leaves frames that decode to all zeros unwritten, as dd conv=sparse
 * does: the target must not care what those blocks hold (a freshly formatted
 * partition, where btrfs references none of them).
 *
 * Exit status of write: 0 written and synced; 2 the image is not one this
 * tool writes (no valid seek table, or bad arguments), nothing written, so the
 * caller can write it another way; 1 failed: the target could not be used
 * (missing, in use, too small) or the write failed partway.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <zstd.h>

#define FRAME_SIZE	(256 << 10)	/* pack: image bytes per frame */
#define MAX_FRAME	(16 << 20)	/* write: largest frame accepted */
#define ALIGN		4096		/* O_DIRECT: sizes and offsets */
#define LEVEL		3
#define MAX_THREADS	64

/* The seekable format: a skippable frame of 8-byte entries and a footer. */
#define SEEK_TABLE_MAGIC	0x184D2A5Eu	/* skippable frame magic */
#define SEEKABLE_MAGIC		0x8F92EAB1u	/* last 4 bytes of the file */
#define SKIP_HEADER		8		/* magic, frame size */
#define FOOTER			9		/* frames, descriptor, magic */
#define ENTRY			8		/* compressed, decompressed size */

enum { FAILED = 1, REFUSED = 2 };

struct frame {
	size_t src;	/* offset in the image file */
	size_t csize;	/* compressed size */
	off_t dst;	/* offset on the target */
	size_t dsize;	/* decompressed size */
};

static const uint8_t *image;
static struct frame *frames;
static size_t nframes, max_dsize;
static int target_fd;
static uint8_t *zero_frame;
static size_t zero_frame_size;
static atomic_size_t next_frame, bytes_written, zero_frames;
static atomic_int failed;
static volatile sig_atomic_t writing;

static void die(int status, const char *fmt, ...)
{
	va_list ap;

	fputs("omarchy-image-write: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(status);
}

/* The image is mmapped, so a read error on the medium arrives as SIGBUS. */
static void on_sigbus(int sig)
{
	static const char msg[] = "omarchy-image-write: read error on the image\n";

	(void)sig;
	(void)!write(STDERR_FILENO, msg, sizeof(msg) - 1);
	_exit(writing ? FAILED : REFUSED);
}

static uint32_t get_le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static const uint8_t *map_file(const char *path, size_t *size, int status)
{
	struct stat st;
	void *p;
	int fd;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) < 0)
		die(status, "%s: %s", path, strerror(errno));
	if (st.st_size == 0)
		die(status, "%s: empty", path);
	p = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (p == MAP_FAILED)
		die(status, "%s: %s", path, strerror(errno));
	close(fd);
	*size = st.st_size;
	return p;
}

/* How pack compresses a frame; write encodes its zero frame the same way. */
static ZSTD_CCtx *pack_cctx(void)
{
	ZSTD_CCtx *cctx = ZSTD_createCCtx();

	if (!cctx)
		die(FAILED, "out of memory");
	ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, LEVEL);
	ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1);
	return cctx;
}

static int pack(const char *raw, const char *out)
{
	size_t size, n, i, tsize, bound = ZSTD_compressBound(FRAME_SIZE);
	const uint8_t *in = map_file(raw, &size, FAILED);
	ZSTD_CCtx *cctx = pack_cctx();
	uint8_t *buf = malloc(bound), *table;
	FILE *f;

	if (size % ALIGN)
		die(FAILED, "%s: %zu bytes, not a multiple of %d", raw, size, ALIGN);
	n = (size + FRAME_SIZE - 1) / FRAME_SIZE;
	if (n > (UINT32_MAX - FOOTER) / ENTRY)
		die(FAILED, "%s: too big for a seek table", raw);
	tsize = SKIP_HEADER + n * ENTRY + FOOTER;
	table = malloc(tsize);
	f = fopen(out, "wbe");
	if (!f || !buf || !table)
		die(FAILED, "%s: %s", out, strerror(errno));

	for (i = 0; i < n; i++) {
		size_t pos = i * FRAME_SIZE;
		size_t len = size - pos < FRAME_SIZE ? size - pos : FRAME_SIZE;
		size_t c = ZSTD_compress2(cctx, buf, bound, in + pos, len);

		if (ZSTD_isError(c))
			die(FAILED, "frame %zu: %s", i, ZSTD_getErrorName(c));
		if (fwrite(buf, 1, c, f) != c)
			die(FAILED, "%s: %s", out, strerror(errno));
		put_le32(table + SKIP_HEADER + i * ENTRY, c);
		put_le32(table + SKIP_HEADER + i * ENTRY + 4, len);
	}

	put_le32(table, SEEK_TABLE_MAGIC);
	put_le32(table + 4, n * ENTRY + FOOTER);
	put_le32(table + SKIP_HEADER + n * ENTRY, n);
	table[SKIP_HEADER + n * ENTRY + 4] = 0;		/* no per-entry checksums */
	put_le32(table + SKIP_HEADER + n * ENTRY + 5, SEEKABLE_MAGIC);
	if (fwrite(table, 1, tsize, f) != tsize || fclose(f))
		die(FAILED, "%s: %s", out, strerror(errno));

	ZSTD_freeCCtx(cctx);
	free(buf);
	free(table);
	munmap((void *)in, size);
	return 0;
}

/*
 * Place every frame from the seek table at the end of the file, touching none
 * of the frames. Everything the table claims is checked against the file: the
 * frames must cover it exactly up to the table, and each must decode to a size
 * O_DIRECT can write. A frame whose data disagrees with its entry fails later,
 * when it decodes to a different size or its checksum does not match.
 */
static off_t read_seek_table(size_t size)
{
	const uint8_t *footer = image + size - FOOTER;
	size_t n, table, pos = 0;
	off_t dst = 0;

	if (size < SKIP_HEADER + FOOTER || get_le32(footer + 5) != SEEKABLE_MAGIC)
		die(REFUSED, "no seek table: not an image packed by omarchy-image-write");
	n = get_le32(footer);
	if (footer[4] != 0)
		die(REFUSED, "seek table: unsupported descriptor 0x%02x", footer[4]);
	if (n == 0 || n > (size - SKIP_HEADER - FOOTER) / ENTRY)
		die(REFUSED, "seek table: %zu frames do not fit a %zu-byte file", n, size);
	table = size - FOOTER - n * ENTRY - SKIP_HEADER;
	if (get_le32(image + table) != SEEK_TABLE_MAGIC ||
	    get_le32(image + table + 4) != n * ENTRY + FOOTER)
		die(REFUSED, "seek table: bad frame header at byte %zu", table);

	frames = calloc(n, sizeof(*frames));
	if (!frames)
		die(REFUSED, "out of memory");
	for (nframes = 0; nframes < n; nframes++) {
		const uint8_t *e = image + table + SKIP_HEADER + nframes * ENTRY;
		size_t c = get_le32(e), d = get_le32(e + 4);

		if (c == 0 || c > table - pos || d == 0 || d > MAX_FRAME || d % ALIGN)
			die(REFUSED, "seek table: frame %zu: %zu bytes decoding to %zu", nframes, c, d);
		frames[nframes] = (struct frame){ pos, c, dst, d };
		if (d > max_dsize)
			max_dsize = d;
		pos += c;
		dst += d;
	}
	if (pos != table)
		die(REFUSED, "seek table: frames cover %zu of the %zu bytes before it", pos, table);
	return dst;
}

/*
 * pack's encoding of a full-size frame of zeros, made here the same way. zstd
 * encodes the same input with the same settings to the same bytes, so a frame
 * identical to it decodes to zeros and is skipped without decoding: 7,162 of
 * the root image's 26,124 frames. If the libzstd that packed the image
 * encoded zeros differently, nothing matches and every frame is decoded,
 * which is only slower.
 */
static void encode_zero_frame(void)
{
	size_t bound = ZSTD_compressBound(max_dsize);
	ZSTD_CCtx *cctx = pack_cctx();
	void *zeros = calloc(1, max_dsize);

	zero_frame = malloc(bound);
	if (!zeros || !zero_frame)
		die(FAILED, "out of memory");
	zero_frame_size = ZSTD_compress2(cctx, zero_frame, bound, zeros, max_dsize);
	if (ZSTD_isError(zero_frame_size))
		zero_frame_size = 0;
	free(zeros);
	ZSTD_freeCCtx(cctx);
}

static int is_zero_frame(const struct frame *f)
{
	return f->dsize == max_dsize && f->csize == zero_frame_size &&
	       memcmp(image + f->src, zero_frame, zero_frame_size) == 0;
}

/* All zero: the first byte is 0 and every byte equals the next one. */
static int all_zero(const uint8_t *p, size_t n)
{
	return p[0] == 0 && memcmp(p, p + 1, n - 1) == 0;
}

static int pwrite_all(int fd, const uint8_t *p, size_t n, off_t off)
{
	while (n) {
		ssize_t r = pwrite(fd, p, n, off);

		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return r < 0 ? -errno : -EIO;
		p += r;
		n -= r;
		off += r;
	}
	return 0;
}

static void fail(const char *fmt, ...)
{
	va_list ap;

	if (atomic_exchange(&failed, 1))
		return;		/* the first error is the one worth reading */
	fputs("omarchy-image-write: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static void *worker(void *arg)
{
	ZSTD_DCtx *dctx = ZSTD_createDCtx();
	uint8_t *buf = NULL;

	(void)arg;
	if (!dctx || posix_memalign((void **)&buf, ALIGN, max_dsize)) {
		fail("out of memory");
		goto out;
	}
	while (!atomic_load(&failed)) {
		size_t k = atomic_fetch_add(&next_frame, 1);
		const struct frame *f;
		size_t n;
		int err;

		if (k >= nframes)
			break;
		f = &frames[k];
		if (is_zero_frame(f)) {
			atomic_fetch_add(&zero_frames, 1);
			continue;
		}
		n = ZSTD_decompressDCtx(dctx, buf, f->dsize, image + f->src, f->csize);
		if (ZSTD_isError(n) || n != f->dsize) {
			fail("frame %zu: %s", k, ZSTD_isError(n) ?
			     ZSTD_getErrorName(n) : "decoded to the wrong size");
			break;
		}
		if (all_zero(buf, n)) {
			atomic_fetch_add(&zero_frames, 1);
			continue;
		}
		err = pwrite_all(target_fd, buf, n, f->dst);
		if (err) {
			fail("write at byte %lld: %s", (long long)f->dst, strerror(-err));
			break;
		}
		atomic_fetch_add(&bytes_written, n);
	}
out:
	free(buf);
	ZSTD_freeDCtx(dctx);
	return NULL;
}

static uint64_t target_size(int fd, const char *path)
{
	struct stat st;
	uint64_t size;

	if (fstat(fd, &st) < 0)
		die(FAILED, "%s: %s", path, strerror(errno));
	if (S_ISREG(st.st_mode))
		return st.st_size;
	if (S_ISBLK(st.st_mode) && ioctl(fd, BLKGETSIZE64, &size) == 0)
		return size;
	die(FAILED, "%s: not a block device or a regular file", path);
	return 0;
}

static int write_image(const char *path, const char *target, int threads)
{
	pthread_t tid[MAX_THREADS];
	struct timespec t0, t1;
	size_t size;
	off_t total;
	int i;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	image = map_file(path, &size, REFUSED);
	total = read_seek_table(size);
	encode_zero_frame();

	/*
	 * O_DIRECT, so the data goes straight to the drive instead of piling up
	 * as dirty page cache for fsync to flush. O_EXCL, so the kernel refuses
	 * a block device that is mounted or otherwise in use (EBUSY).
	 */
	target_fd = open(target, O_WRONLY | O_DIRECT | O_EXCL | O_CLOEXEC);
	if (target_fd < 0)
		die(FAILED, "%s: %s", target, strerror(errno));
	if (target_size(target_fd, target) < (uint64_t)total)
		die(FAILED, "%s: smaller than the %lld-byte image", target, (long long)total);

	writing = 1;
	for (i = 0; i < threads; i++)
		if (pthread_create(&tid[i], NULL, worker, NULL))
			break;
	if (i == 0)
		die(FAILED, "cannot start a thread");
	while (i--)
		pthread_join(tid[i], NULL);
	if (atomic_load(&failed))
		return FAILED;
	if (fsync(target_fd) || close(target_fd))
		die(FAILED, "%s: %s", target, strerror(errno));

	clock_gettime(CLOCK_MONOTONIC, &t1);
	fprintf(stderr, "omarchy-image-write: wrote %.2f of %.2f GiB (%zu frames, %zu zero, %d threads) in %.2f s\n",
		atomic_load(&bytes_written) / 1073741824.0, total / 1073741824.0, nframes,
		atomic_load(&zero_frames), threads,
		(t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
	return 0;
}

int main(int argc, char **argv)
{
	signal(SIGBUS, on_sigbus);

	if (argc == 4 && !strcmp(argv[1], "pack"))
		return pack(argv[2], argv[3]);
	if ((argc == 4 || argc == 5) && !strcmp(argv[1], "write")) {
		long cpus = sysconf(_SC_NPROCESSORS_ONLN);
		int threads = cpus < 1 ? 1 : cpus > 16 ? 16 : cpus;

		if (argc == 5)
			threads = atoi(argv[4]);
		if (threads < 1 || threads > MAX_THREADS)
			die(REFUSED, "threads: 1 to %d", MAX_THREADS);
		return write_image(argv[2], argv[3], threads);
	}
	die(REFUSED, "usage: omarchy-image-write pack RAW IMAGE.zst\n"
	    "       omarchy-image-write write IMAGE.zst TARGET [THREADS]");
}
