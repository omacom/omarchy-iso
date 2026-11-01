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
 *   omarchy-image-write pack           RAW IMAGE.zst
 *   omarchy-image-write write          IMAGE.zst TARGET [THREADS]
 *   omarchy-image-write write-squashfs IMAGE.sfs TARGET [THREADS]
 *
 * write-squashfs writes the one file inside a squashfs built for it, the
 * ISO's omarchy-root.sfs, without mounting it. squashfs compresses every
 * block of a file on its own and lists their sizes in the file's inode, so
 * that list is a seek table too: each block becomes a frame, decoded here
 * with libzstd like the frames of write. Read through a mount instead, the
 * kernel's squashfs decodes the same blocks behind one loop device and takes
 * 1.7 s for this image where libzstd takes 1.0 s (i5-12600K, page cache warm),
 * and the page cache it fills is the decoded file's, so the order below
 * could not tell what the verify left cached. The squashfs must hold one
 * regular file, compressed with zstd, without a fragment (mksquashfs
 * -no-fragments).
 *
 * write and write-squashfs leave frames that are all zeros unwritten, as dd
 * conv=sparse does: the target must not care what those blocks hold (a freshly
 * formatted partition, where btrfs references none of them).
 *
 * Exit status of write and write-squashfs: 0 written and synced; 2 the image
 * is not one this tool writes (no valid seek table, a squashfs of another
 * shape, or bad arguments), nothing written, so the caller can write it
 * another way; 1 failed: the target could not be used (missing, in use, too
 * small) or the write failed partway.
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

/* squashfs 4.0, as in the kernel's fs/squashfs/squashfs_fs.h. */
#define SQUASHFS_MAGIC		0x73717368u
#define SQUASHFS_ZSTD		6
#define SQUASHFS_SUPER		96
#define SQUASHFS_METADATA	8192
#define SQUASHFS_META_STORED	(1 << 15)	/* metadata block not compressed */
#define SQUASHFS_BLOCK_STORED	(1 << 24)	/* data block not compressed */
#define SQUASHFS_INVALID_FRAG	0xffffffffu
#define SQUASHFS_REG_TYPE	2
#define SQUASHFS_LREG_TYPE	9

enum { FAILED = 1, REFUSED = 2 };

struct frame {
	size_t src;	/* offset in the image file */
	size_t csize;	/* compressed size; 0: a sparse squashfs block, zeros */
	off_t dst;	/* offset on the target */
	size_t dsize;	/* decompressed size */
	int stored;	/* a squashfs block kept uncompressed: copied as it is */
};

static const uint8_t *image;
static struct frame *frames;
static size_t *order;		/* the frames in the order they are written */
static size_t nframes, max_dsize, cached_frames;
static int target_fd;
static uint8_t *zero_frame;
static size_t zero_frame_size;
static atomic_size_t next_frame, bytes_written, zero_frames;
static atomic_int failed;
static int squashfs_input;	/* write-squashfs: frames are squashfs blocks */
/* Thread-nanoseconds, summed over the workers: decoding (including the page
 * faults on the image), in pwrite, and checking for zeros (the compressed
 * bytes against the zero frame, or a decoded frame for all zeros). */
static atomic_uint_fast64_t decode_ns, write_ns, skip_ns;
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

static uint16_t get_le16(const uint8_t *p)
{
	return p[0] | p[1] << 8;
}

static uint64_t get_le64(const uint8_t *p)
{
	return get_le32(p) | (uint64_t)get_le32(p + 4) << 32;
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

/* All zero: the first byte is 0 and every byte equals the next one. */
static int all_zero(const uint8_t *p, size_t n)
{
	return p[0] == 0 && memcmp(p, p + 1, n - 1) == 0;
}

static int pack(const char *raw, const char *out)
{
	size_t size, n, i, tsize, zeros = 0, packed = 0, bound = ZSTD_compressBound(FRAME_SIZE);
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
		zeros += all_zero(in + pos, len);
		packed += c;
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
	fprintf(stderr, "omarchy-image-write: packed %.2f GiB as %zu frames (%zu zero) into %.2f GiB\n",
		size / 1073741824.0, n, zeros, (packed + tsize) / 1073741824.0);

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
		frames[nframes] = (struct frame){ pos, c, dst, d, 0 };
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
 * The inode table, decoded: metadata blocks of up to 8 KiB, each behind a
 * 2-byte header with its size and whether it is compressed, from the table's
 * start to the directory table's.
 */
static uint8_t *squashfs_inodes(uint64_t start, uint64_t end, size_t size, size_t *len)
{
	uint8_t *out = NULL;
	uint64_t pos = start;
	size_t cap = 0;

	*len = 0;
	while (pos < end) {
		uint16_t h;
		size_t c, n;

		if (pos + 2 > size)
			die(REFUSED, "squashfs: inode table runs past the file");
		h = get_le16(image + pos);
		c = h & ~SQUASHFS_META_STORED;
		pos += 2;
		if (c == 0 || c > SQUASHFS_METADATA || pos + c > end)
			die(REFUSED, "squashfs: bad metadata block at byte %llu", (unsigned long long)pos - 2);
		if (*len + SQUASHFS_METADATA > cap) {
			cap = cap ? 2 * cap : 16 * SQUASHFS_METADATA;
			out = realloc(out, cap);
			if (!out)
				die(REFUSED, "out of memory");
		}
		if (h & SQUASHFS_META_STORED) {
			memcpy(out + *len, image + pos, c);
			n = c;
		} else {
			n = ZSTD_decompress(out + *len, SQUASHFS_METADATA, image + pos, c);
			if (ZSTD_isError(n))
				die(REFUSED, "squashfs: inode table: %s", ZSTD_getErrorName(n));
		}
		*len += n;
		pos += c;
	}
	return out;
}

/*
 * write-squashfs: the frames are the data blocks of the squashfs's one file,
 * read from its inode. mksquashfs writes a directory's entries before the
 * directory, so with one file and the root directory the file's inode comes
 * first. Its blocks lie back to back from start_block, each the size its list
 * entry gives; a 0 entry is a block of zeros that was never stored.
 */
static off_t squashfs_frames(size_t size)
{
	const uint8_t *sb = image;
	uint64_t file_size, start, used, end, pos;
	size_t len, head, k, bs;
	uint32_t frag;
	uint8_t *in;
	off_t dst = 0;

	if (size < SQUASHFS_SUPER || get_le32(sb) != SQUASHFS_MAGIC || get_le16(sb + 28) != 4)
		die(REFUSED, "not a squashfs 4.0 image");
	if (get_le16(sb + 20) != SQUASHFS_ZSTD)
		die(REFUSED, "squashfs: compressed with %u, not zstd", get_le16(sb + 20));
	if (get_le32(sb + 4) != 2)
		die(REFUSED, "squashfs: %u inodes, not one file in the root directory", get_le32(sb + 4));
	bs = get_le32(sb + 12);
	used = get_le64(sb + 40);
	start = get_le64(sb + 64);
	end = get_le64(sb + 72);
	if (bs == 0 || bs % ALIGN || bs > MAX_FRAME || used > size || start >= end || end > used)
		die(REFUSED, "squashfs: bad superblock");

	in = squashfs_inodes(start, end, size, &len);
	if (len < 16)
		die(REFUSED, "squashfs: empty inode table");
	switch (get_le16(in)) {
	case SQUASHFS_LREG_TYPE:
		if (len < 56)
			die(REFUSED, "squashfs: short inode");
		pos = get_le64(in + 16);
		file_size = get_le64(in + 24);
		frag = get_le32(in + 44);
		head = 56;
		break;
	case SQUASHFS_REG_TYPE:
		if (len < 32)
			die(REFUSED, "squashfs: short inode");
		pos = get_le32(in + 16);
		frag = get_le32(in + 20);
		file_size = get_le32(in + 28);
		head = 32;
		break;
	default:
		die(REFUSED, "squashfs: the first inode is not a regular file");
	}
	if (frag != SQUASHFS_INVALID_FRAG)
		die(REFUSED, "squashfs: the file ends in a fragment (build it with -no-fragments)");
	/* Bounds on what the inode claims, so no sum below can wrap: the
	 * blocks lie between the superblock and the inode table, and the file
	 * is no bigger than off_t, as the kernel's own reader requires. */
	if (pos < SQUASHFS_SUPER || pos > start)
		die(REFUSED, "squashfs: blocks start at byte %llu, outside the data", (unsigned long long)pos);
	if (file_size == 0 || file_size % ALIGN || file_size > INT64_MAX)
		die(REFUSED, "squashfs: the file is %llu bytes, not a multiple of %d",
		    (unsigned long long)file_size, ALIGN);
	nframes = file_size / bs + (file_size % bs != 0);
	if (len < head + nframes * 4)
		die(REFUSED, "squashfs: block list runs past the inode table");

	frames = calloc(nframes, sizeof(*frames));
	if (!frames)
		die(REFUSED, "out of memory");
	for (k = 0; k < nframes; k++) {
		uint32_t e = get_le32(in + head + k * 4);
		size_t c = e & ~SQUASHFS_BLOCK_STORED;
		size_t d = file_size - dst < bs ? file_size - dst : bs;

		if (c > MAX_FRAME || c > start - pos)
			die(REFUSED, "squashfs: block %zu: %zu bytes at byte %llu", k, c, (unsigned long long)pos);
		if ((e & SQUASHFS_BLOCK_STORED) && c != d)
			die(REFUSED, "squashfs: stored block %zu is %zu bytes, not %zu", k, c, d);
		frames[k] = (struct frame){ pos, c, dst, d, !!(e & SQUASHFS_BLOCK_STORED) };
		if (d > max_dsize)
			max_dsize = d;
		pos += c;
		dst += d;
	}
	free(in);
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

static uint64_t now_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
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
	uint64_t decode = 0, write = 0, skip = 0, t0, t1;

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
		k = order[k];
		f = &frames[k];
		t0 = now_ns();
		if (f->csize == 0 || (!squashfs_input && is_zero_frame(f))) {
			atomic_fetch_add(&zero_frames, 1);
			skip += now_ns() - t0;
			continue;
		}
		if (f->stored) {
			memcpy(buf, image + f->src, f->dsize);
			n = f->dsize;
		} else {
			n = ZSTD_decompressDCtx(dctx, buf, f->dsize, image + f->src, f->csize);
		}
		t1 = now_ns();
		decode += t1 - t0;
		if (ZSTD_isError(n) || n != f->dsize) {
			fail("frame %zu: %s", k, ZSTD_isError(n) ?
			     ZSTD_getErrorName(n) : "decoded to the wrong size");
			break;
		}
		if (all_zero(buf, n)) {
			atomic_fetch_add(&zero_frames, 1);
			skip += now_ns() - t1;
			continue;
		}
		t0 = now_ns();
		skip += t0 - t1;
		err = pwrite_all(target_fd, buf, n, f->dst);
		write += now_ns() - t0;
		if (err) {
			fail("write at byte %lld: %s", (long long)f->dst, strerror(-err));
			break;
		}
		atomic_fetch_add(&bytes_written, n);
	}
out:
	atomic_fetch_add(&decode_ns, decode);
	atomic_fetch_add(&write_ns, write);
	atomic_fetch_add(&skip_ns, skip);
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

/*
 * The order to write the frames in: the ones whose compressed bytes the page
 * cache already holds first, then the rest in file order. On a machine whose
 * RAM cannot hold the whole image, the boot-time verify leaves only part of it
 * cached; written in file order, the reads of the uncached frames would evict
 * those pages before their turn came, and the medium would be read twice over.
 * The uncached frames are then read sequentially, so the kernel reads ahead
 * and drops each page once it has been decoded.
 */
static int frame_cached(const unsigned char *vec, const struct frame *f, size_t page)
{
	size_t p = f->src / page, end = (f->src + f->csize + page - 1) / page;

	while (p < end && (vec[p] & 1))
		p++;
	return p == end;
}

/*
 * Which pages of the image the page cache holds, taken before this tool reads
 * any of it: reading the seek table faults in its surroundings too (btrfs
 * reads ahead at least 4 MiB), which says nothing about what the verify left.
 */
static unsigned char *cache_snapshot(size_t size)
{
	size_t page = sysconf(_SC_PAGESIZE);
	unsigned char *vec = malloc((size + page - 1) / page);

	if (vec && mincore((void *)image, size, vec) == 0)
		return vec;
	free(vec);
	return NULL;
}

static void plan_order(size_t size, unsigned char *vec)
{
	size_t page = sysconf(_SC_PAGESIZE), k, n = 0;

	order = malloc(nframes * sizeof(*order));
	if (!order)
		die(REFUSED, "out of memory");
	if (vec) {
		for (k = 0; k < nframes; k++)
			if (frame_cached(vec, &frames[k], page))
				order[n++] = k;
		cached_frames = n;
		for (k = 0; k < nframes; k++)
			if (!frame_cached(vec, &frames[k], page))
				order[n++] = k;
		madvise((void *)image, size, MADV_SEQUENTIAL);
	} else {
		for (k = 0; k < nframes; k++)
			order[k] = k;
	}
	free(vec);
}

static int write_image(const char *path, const char *target, int threads)
{
	pthread_t tid[MAX_THREADS];
	uint64_t t0, t1, t2, t3;
	unsigned char *cached;
	size_t size;
	off_t total;
	int i, started;

	t0 = now_ns();
	image = map_file(path, &size, REFUSED);
	cached = cache_snapshot(size);
	if (squashfs_input) {
		total = squashfs_frames(size);
	} else {
		total = read_seek_table(size);
		encode_zero_frame();
	}
	plan_order(size, cached);

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
	t1 = now_ns();
	for (i = 0; i < threads; i++)
		if (pthread_create(&tid[i], NULL, worker, NULL))
			break;
	if (i == 0)
		die(FAILED, "cannot start a thread");
	started = i;
	while (i--)
		pthread_join(tid[i], NULL);
	t2 = now_ns();
	if (atomic_load(&failed))
		return FAILED;
	if (fsync(target_fd) || close(target_fd))
		die(FAILED, "%s: %s", target, strerror(errno));
	t3 = now_ns();

	fprintf(stderr, "omarchy-image-write: wrote %.2f of %.2f GiB (%zu frames, %zu zero, %zu cached, %d threads) in %.2f s\n",
		atomic_load(&bytes_written) / 1073741824.0, total / 1073741824.0, nframes,
		atomic_load(&zero_frames), cached_frames, threads, (t3 - t0) / 1e9);
	/*
	 * Where the time went: before the first frame, the frames, the final
	 * flush; and the workers' thread-seconds, so a slow install says whether
	 * the drive (writing) or the CPU (decoding) held it up.
	 */
	fprintf(stderr, "omarchy-image-write: setup %.3f s, frames %.3f s (%.2f GiB/s), fsync %.3f s; "
		"thread-seconds decoding %.2f, writing %.2f, skipping %.2f, of %.2f\n",
		(t1 - t0) / 1e9, (t2 - t1) / 1e9,
		t2 > t1 ? atomic_load(&bytes_written) / 1073741824.0 / ((t2 - t1) / 1e9) : 0,
		(t3 - t2) / 1e9, atomic_load(&decode_ns) / 1e9, atomic_load(&write_ns) / 1e9,
		atomic_load(&skip_ns) / 1e9, started * (t2 - t1) / 1e9);
	return 0;
}

int main(int argc, char **argv)
{
	signal(SIGBUS, on_sigbus);

	if (argc == 4 && !strcmp(argv[1], "pack"))
		return pack(argv[2], argv[3]);
	if ((argc == 4 || argc == 5) && (!strcmp(argv[1], "write") || !strcmp(argv[1], "write-squashfs"))) {
		long cpus = sysconf(_SC_NPROCESSORS_ONLN);
		int threads = cpus < 1 ? 1 : cpus > 16 ? 16 : cpus;

		if (argc == 5) {
			char *end;
			long n;

			errno = 0;
			n = strtol(argv[4], &end, 10);
			threads = errno || end == argv[4] || *end || n < 1 || n > MAX_THREADS ? 0 : n;
		}
		if (threads < 1 || threads > MAX_THREADS)
			die(REFUSED, "threads: 1 to %d", MAX_THREADS);
		squashfs_input = !strcmp(argv[1], "write-squashfs");
		return write_image(argv[2], argv[3], threads);
	}
	die(REFUSED, "usage: omarchy-image-write pack RAW IMAGE.zst\n"
	    "       omarchy-image-write write IMAGE.zst TARGET [THREADS]\n"
	    "       omarchy-image-write write-squashfs IMAGE.sfs TARGET [THREADS]");
}
