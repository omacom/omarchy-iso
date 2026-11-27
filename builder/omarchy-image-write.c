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
#define MAX_BATCH	16		/* max consecutive frames per worker grab */
#define READ_CHUNK	(4 << 20)	/* max coalesced sequential read for uncached frames */
#define DROP_WINDOW	(16 << 20)	/* drop uncached source pages after this many bytes */
#define MAX_RING_SLOTS	64
#define MAX_RING_BYTES	(32 << 20)

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
static size_t nframes, max_dsize, max_csize, cached_frames, frame_batch = 1;
static size_t stage1_limit;
static int src_fd = -1, target_fd, uncached_mode;
static uint8_t *zero_frame;
static size_t zero_frame_size;
static _Alignas(64) atomic_size_t next_frame;
static _Alignas(64) atomic_size_t stage2_taken;
static atomic_size_t bytes_written, zero_frames;
static atomic_int failed;
static pthread_mutex_t done_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t done_cv;
static int done_count, expected_workers;
static int squashfs_input;	/* write-squashfs: frames are squashfs blocks */

/*
 * Stage 1 -> Stage 2 handoff and bounded frame pool, used only when
 * cached_frames < nframes. Fully cached runs (machines with enough RAM to keep
 * the whole image warm) skip these completely and run the lock-free pread path.
 */
struct read_slot {
	uint8_t *data;
	size_t frame_idx;
};

static pthread_mutex_t stage_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t stage_cv = PTHREAD_COND_INITIALIZER;
static int workers_ready, stage1_done, stage2_start;

static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t q_not_full = PTHREAD_COND_INITIALIZER;
static struct read_slot *ring_slots;
static uint8_t *ring_buf;
static size_t *free_stack, *ready_queue;
static size_t ring_cap, free_count, ready_head, ready_tail, ready_count;
static int reader_done;

/* Thread-nanoseconds, summed over the workers: reading and decoding the source
 * frames, in pwrite, and checking for zeros (the compressed bytes against the
 * zero frame, or a decoded frame for all zeros). */
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

static const uint8_t *map_fd(int fd, const char *path, size_t *size, int status)
{
	struct stat st;
	void *p;

	if (fstat(fd, &st) < 0)
		die(status, "%s: %s", path, strerror(errno));
	if (st.st_size == 0)
		die(status, "%s: empty", path);
	p = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (p == MAP_FAILED)
		die(status, "%s: %s", path, strerror(errno));
	*size = st.st_size;
	return p;
}

static const uint8_t *map_file(const char *path, size_t *size, int status)
{
	const uint8_t *p;
	int fd;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		die(status, "%s: %s", path, strerror(errno));
	p = map_fd(fd, path, size, status);
	close(fd);
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

struct pack_slot {
	uint8_t *buf;
	size_t csize;
	size_t dsize;
	int zero;
	int ready;
};

struct pack_ctx {
	const uint8_t *in;
	size_t size, nframes, bound, ring;
	const uint8_t *zero_frame;
	size_t zero_frame_size;
	struct pack_slot *slots;
	atomic_size_t next;
	size_t written;
	pthread_mutex_t mu;
	pthread_cond_t cv;
	atomic_int failed;
};

static void *pack_worker(void *arg)
{
	struct pack_ctx *ctx = arg;
	ZSTD_CCtx *cctx = pack_cctx();

	for (;;) {
		size_t k = atomic_fetch_add(&ctx->next, 1);
		size_t pos, len, c;
		struct pack_slot *slot;
		int is_zero;

		if (k >= ctx->nframes || atomic_load(&ctx->failed))
			break;
		pos = k * FRAME_SIZE;
		len = ctx->size - pos < FRAME_SIZE ? ctx->size - pos : FRAME_SIZE;
		slot = &ctx->slots[k % ctx->ring];

		pthread_mutex_lock(&ctx->mu);
		while (k >= ctx->written + ctx->ring && !atomic_load(&ctx->failed))
			pthread_cond_wait(&ctx->cv, &ctx->mu);
		pthread_mutex_unlock(&ctx->mu);
		if (atomic_load(&ctx->failed))
			break;

		is_zero = all_zero(ctx->in + pos, len);
		if (is_zero && len == FRAME_SIZE && ctx->zero_frame_size > 0) {
			memcpy(slot->buf, ctx->zero_frame, ctx->zero_frame_size);
			c = ctx->zero_frame_size;
		} else {
			c = ZSTD_compress2(cctx, slot->buf, ctx->bound, ctx->in + pos, len);
			if (ZSTD_isError(c)) {
				if (!atomic_exchange(&ctx->failed, 1))
					fprintf(stderr, "omarchy-image-write: frame %zu: %s\n",
						k, ZSTD_getErrorName(c));
				pthread_mutex_lock(&ctx->mu);
				pthread_cond_broadcast(&ctx->cv);
				pthread_mutex_unlock(&ctx->mu);
				break;
			}
		}

		pthread_mutex_lock(&ctx->mu);
		slot->csize = c;
		slot->dsize = len;
		slot->zero = is_zero;
		slot->ready = 1;
		pthread_cond_broadcast(&ctx->cv);
		pthread_mutex_unlock(&ctx->mu);
	}
	ZSTD_freeCCtx(cctx);
	return NULL;
}

static int pack(const char *raw, const char *out)
{
	size_t size, n, i, tsize, zeros = 0, packed = 0, bound = ZSTD_compressBound(FRAME_SIZE);
	const uint8_t *in = map_file(raw, &size, FAILED);
	long cpus = sysconf(_SC_NPROCESSORS_ONLN);
	int threads = cpus < 1 ? 1 : cpus > 16 ? 16 : (int)cpus, started = 0;
	pthread_t tid[MAX_THREADS];
	uint8_t *bufs = NULL, *zbuf = NULL, *table;
	void *zraw = NULL;
	struct pack_ctx ctx;
	ZSTD_CCtx *zcctx;
	FILE *f;

	if (size % ALIGN)
		die(FAILED, "%s: %zu bytes, not a multiple of %d", raw, size, ALIGN);
	n = (size + FRAME_SIZE - 1) / FRAME_SIZE;
	if (n > (UINT32_MAX - FOOTER) / ENTRY)
		die(FAILED, "%s: too big for a seek table", raw);
	if ((size_t)threads > n)
		threads = (int)n;
	tsize = SKIP_HEADER + n * ENTRY + FOOTER;
	table = malloc(tsize);
	f = fopen(out, "wbe");

	memset(&ctx, 0, sizeof(ctx));
	ctx.in = in;
	ctx.size = size;
	ctx.nframes = n;
	ctx.bound = bound;
	ctx.ring = (size_t)threads * 4;
	ctx.slots = calloc(ctx.ring, sizeof(*ctx.slots));
	bufs = malloc(ctx.ring * bound);
	zbuf = malloc(bound);
	zraw = calloc(1, FRAME_SIZE);
	if (!f || !table || !ctx.slots || !bufs || !zbuf || !zraw)
		die(FAILED, "%s: %s", out, strerror(errno));
	for (i = 0; i < ctx.ring; i++)
		ctx.slots[i].buf = bufs + i * bound;

	/* Pre-encode a full zero frame once so workers copy it instead of recompressing. */
	zcctx = pack_cctx();
	ctx.zero_frame_size = ZSTD_compress2(zcctx, zbuf, bound, zraw, FRAME_SIZE);
	if (ZSTD_isError(ctx.zero_frame_size))
		ctx.zero_frame_size = 0;
	ctx.zero_frame = zbuf;
	ZSTD_freeCCtx(zcctx);
	free(zraw);

	pthread_mutex_init(&ctx.mu, NULL);
	pthread_cond_init(&ctx.cv, NULL);
	for (int t = 0; t < threads; t++) {
		if (pthread_create(&tid[t], NULL, pack_worker, &ctx) != 0)
			break;
		started++;
	}
	if (started == 0)
		die(FAILED, "cannot start a thread");

	for (i = 0; i < n; i++) {
		struct pack_slot *slot = &ctx.slots[i % ctx.ring];
		size_t c, len;

		pthread_mutex_lock(&ctx.mu);
		while (!slot->ready && !atomic_load(&ctx.failed))
			pthread_cond_wait(&ctx.cv, &ctx.mu);
		if (atomic_load(&ctx.failed)) {
			pthread_mutex_unlock(&ctx.mu);
			break;
		}
		c = slot->csize;
		len = slot->dsize;
		zeros += (size_t)slot->zero;
		pthread_mutex_unlock(&ctx.mu);

		packed += c;
		if (fwrite(slot->buf, 1, c, f) != c) {
			if (!atomic_exchange(&ctx.failed, 1))
				fprintf(stderr, "omarchy-image-write: %s: %s\n", out, strerror(errno));
			pthread_mutex_lock(&ctx.mu);
			pthread_cond_broadcast(&ctx.cv);
			pthread_mutex_unlock(&ctx.mu);
			break;
		}
		put_le32(table + SKIP_HEADER + i * ENTRY, c);
		put_le32(table + SKIP_HEADER + i * ENTRY + 4, len);

		pthread_mutex_lock(&ctx.mu);
		slot->ready = 0;
		ctx.written = i + 1;
		pthread_cond_broadcast(&ctx.cv);
		pthread_mutex_unlock(&ctx.mu);
	}

	while (started--)
		pthread_join(tid[started], NULL);
	pthread_cond_destroy(&ctx.cv);
	pthread_mutex_destroy(&ctx.mu);

	if (atomic_load(&ctx.failed)) {
		fclose(f);
		free(ctx.slots);
		free(bufs);
		free(zbuf);
		free(table);
		munmap((void *)in, size);
		return FAILED;
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

	free(ctx.slots);
	free(bufs);
	free(zbuf);
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
	const uint8_t *footer;
	size_t n, table, pos = 0;
	off_t dst = 0;

	if (size < SKIP_HEADER + FOOTER)
		die(REFUSED, "no seek table: not an image packed by omarchy-image-write");
	footer = image + size - FOOTER;
	if (get_le32(footer + 5) != SEEKABLE_MAGIC)
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
	size_t max_bound = ZSTD_compressBound(MAX_FRAME);

	for (nframes = 0; nframes < n; nframes++) {
		const uint8_t *e = image + table + SKIP_HEADER + nframes * ENTRY;
		size_t c = get_le32(e), d = get_le32(e + 4);

		if (c == 0 || c > table - pos || c > max_bound || d == 0 || d > MAX_FRAME || d % ALIGN)
			die(REFUSED, "seek table: frame %zu: %zu bytes decoding to %zu", nframes, c, d);
		frames[nframes] = (struct frame){ pos, c, dst, d, 0 };
		if (d > max_dsize)
			max_dsize = d;
		if (c > max_csize)
			max_csize = c;
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
static uint8_t *squashfs_inodes(uint64_t start, uint64_t end, size_t *len)
{
	uint8_t *out = NULL;
	uint64_t pos = start;
	size_t cap = 0;

	*len = 0;
	while (pos < end) {
		uint16_t h;
		size_t c, n;

		if (pos + 2 > end)
			die(REFUSED, "squashfs: inode table runs past the table end");
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
	uint16_t blog;
	uint32_t frag;
	uint8_t *in;
	off_t dst = 0;

	if (size < SQUASHFS_SUPER || get_le32(sb) != SQUASHFS_MAGIC ||
	    get_le16(sb + 28) != 4 || get_le16(sb + 30) != 0)
		die(REFUSED, "not a squashfs 4.0 image");
	if (get_le16(sb + 20) != SQUASHFS_ZSTD)
		die(REFUSED, "squashfs: compressed with %u, not zstd", get_le16(sb + 20));
	if (get_le32(sb + 4) != 2)
		die(REFUSED, "squashfs: %u inodes, not one file in the root directory", get_le32(sb + 4));
	bs = get_le32(sb + 12);
	blog = get_le16(sb + 22);
	used = get_le64(sb + 40);
	start = get_le64(sb + 64);
	end = get_le64(sb + 72);
	if (blog < 12 || blog > 24 || bs != ((size_t)1 << blog) || bs % ALIGN ||
	    bs > MAX_FRAME || used > size || start < SQUASHFS_SUPER || start >= end || end > used)
		die(REFUSED, "squashfs: bad superblock");

	in = squashfs_inodes(start, end, &len);
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
		if (c > max_csize)
			max_csize = c;
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

static uint64_t now_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static int pread_all(int fd, uint8_t *p, size_t n, off_t off)
{
	while (n) {
		ssize_t r = pread(fd, p, n, off);

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

static void wake_uncached(void)
{
	if (!uncached_mode)
		return;
	pthread_mutex_lock(&stage_mu);
	pthread_cond_broadcast(&stage_cv);
	pthread_mutex_unlock(&stage_mu);
	pthread_mutex_lock(&q_mu);
	pthread_cond_broadcast(&q_not_empty);
	pthread_cond_broadcast(&q_not_full);
	pthread_mutex_unlock(&q_mu);
}

static void fail(const char *fmt, ...)
{
	va_list ap;

	if (atomic_exchange(&failed, 1)) {
		wake_uncached();
		return;		/* the first error is the one worth reading */
	}
	fputs("omarchy-image-write: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	wake_uncached();
}

static void drop_page_range(size_t start, size_t end)
{
	if (end > start)
		posix_fadvise(src_fd, (off_t)start, (off_t)(end - start), POSIX_FADV_DONTNEED);
}

/*
 * Stage 2 reader (only started when cached_frames < nframes).
 *
 * Waits until all workers finish Stage 1 (the cached frames) and drop Stage 1's
 * page cache, then reads the remaining uncached frames sequentially from src_fd
 * in strict file order, coalescing contiguous frames into up to READ_CHUNK
 * pread() calls. Keeping cold reads on one sequential stream prevents N worker
 * threads from fighting over src_fd's single kernel readahead state and BFQ
 * queues on USB media, while workers still decode and pwrite() in parallel.
 */
static void *reader_thread(void *arg)
{
	size_t page = (size_t)sysconf(_SC_PAGESIZE);
	size_t idx = cached_frames;
	size_t drop_start = 0, drop_end = 0;
	uint8_t *read_buf = NULL;
	int have_drop = 0;

	(void)arg;
	if (cached_frames > 0) {
		pthread_mutex_lock(&stage_mu);
		while (!stage2_start && !atomic_load(&failed))
			pthread_cond_wait(&stage_cv, &stage_mu);
		pthread_mutex_unlock(&stage_mu);
	}
	if (atomic_load(&failed))
		goto done;

	read_buf = malloc(READ_CHUNK);
	if (!read_buf) {
		fail("out of memory");
		goto done;
	}

	while (idx < nframes && !atomic_load(&failed)) {
		size_t k0 = order[idx];
		const struct frame *f0 = &frames[k0];

		if (f0->csize == 0) {
			atomic_fetch_add(&zero_frames, 1);
			atomic_fetch_add(&stage2_taken, 1);
			idx++;
			continue;
		}

		if (f0->csize > READ_CHUNK) {
			size_t slot_id;
			int err;

			pthread_mutex_lock(&q_mu);
			while (free_count == 0 && !atomic_load(&failed))
				pthread_cond_wait(&q_not_full, &q_mu);
			if (atomic_load(&failed)) {
				pthread_mutex_unlock(&q_mu);
				break;
			}
			slot_id = free_stack[--free_count];
			pthread_mutex_unlock(&q_mu);

			err = pread_all(src_fd, ring_slots[slot_id].data, f0->csize, (off_t)f0->src);
			if (err) {
				fail("frame %zu: read at byte %zu: %s", k0, f0->src, strerror(-err));
				break;
			}
			ring_slots[slot_id].frame_idx = k0;

			pthread_mutex_lock(&q_mu);
			ready_queue[ready_tail] = slot_id;
			ready_tail = (ready_tail + 1) % ring_cap;
			ready_count++;
			pthread_cond_signal(&q_not_empty);
			pthread_mutex_unlock(&q_mu);

			if (have_drop) {
				drop_page_range(drop_start, drop_end);
				have_drop = 0;
			}
			drop_page_range(f0->src & ~(page - 1), (f0->src + f0->csize) & ~(page - 1));
			idx++;
			continue;
		}

		size_t run_start = f0->src;
		size_t run_end = f0->src + f0->csize;
		size_t end_idx = idx + 1;

		while (end_idx < nframes) {
			const struct frame *fn = &frames[order[end_idx]];

			if (fn->csize == 0 || fn->src != run_end)
				break;
			if ((run_end - run_start) + fn->csize > READ_CHUNK)
				break;
			run_end += fn->csize;
			end_idx++;
		}

		int err = pread_all(src_fd, read_buf, run_end - run_start, (off_t)run_start);
		if (err) {
			fail("frame %zu: read at byte %zu: %s", k0, run_start, strerror(-err));
			break;
		}

		/*
		 * Drop consumed source pages behind the reader so low-RAM
		 * machines do not refill page cache and hit direct reclaim.
		 * Align drop_end down to a page boundary so a trailing partial
		 * page shared with the next contiguous frame stays warm.
		 */
		size_t aligned_start = run_start & ~(page - 1);
		size_t aligned_end = run_end & ~(page - 1);

		if (have_drop && aligned_start > drop_end + page) {
			drop_page_range(drop_start, drop_end);
			have_drop = 0;
		}
		if (!have_drop) {
			drop_start = aligned_start;
			drop_end = aligned_end;
			have_drop = 1;
		} else if (aligned_end > drop_end) {
			drop_end = aligned_end;
		}
		if (drop_end > drop_start && drop_end - drop_start >= DROP_WINDOW) {
			drop_page_range(drop_start, drop_end);
			drop_start = drop_end;
		}

		/* Hand off the coalesced frames to the workers in batches. */
		for (size_t j = idx; j < end_idx && !atomic_load(&failed); ) {
			size_t batch_ids[MAX_RING_SLOTS];
			size_t want = end_idx - j;
			size_t got = 0;

			if (want > ring_cap)
				want = ring_cap;
			pthread_mutex_lock(&q_mu);
			while (free_count == 0 && !atomic_load(&failed))
				pthread_cond_wait(&q_not_full, &q_mu);
			if (atomic_load(&failed)) {
				pthread_mutex_unlock(&q_mu);
				break;
			}
			while (got < want && free_count > 0)
				batch_ids[got++] = free_stack[--free_count];
			pthread_mutex_unlock(&q_mu);

			for (size_t b = 0; b < got; b++) {
				size_t k = order[j + b];
				const struct frame *f = &frames[k];
				size_t slot_id = batch_ids[b];

				memcpy(ring_slots[slot_id].data, read_buf + (f->src - run_start), f->csize);
				ring_slots[slot_id].frame_idx = k;
			}

			pthread_mutex_lock(&q_mu);
			for (size_t b = 0; b < got; b++) {
				ready_queue[ready_tail] = batch_ids[b];
				ready_tail = (ready_tail + 1) % ring_cap;
				ready_count++;
			}
			pthread_cond_broadcast(&q_not_empty);
			pthread_mutex_unlock(&q_mu);
			j += got;
		}

		idx = end_idx;
	}

	/* Drop any trailing pages (including kernel readahead past the last frame). */
	posix_fadvise(src_fd, 0, 0, POSIX_FADV_DONTNEED);

done:
	free(read_buf);
	pthread_mutex_lock(&q_mu);
	reader_done = 1;
	pthread_cond_broadcast(&q_not_empty);
	pthread_mutex_unlock(&q_mu);
	return NULL;
}

static int decode_and_write_frame(ZSTD_DCtx *dctx, uint8_t *buf, const uint8_t *src_data,
				  size_t k, uint64_t t0, uint64_t *decode, uint64_t *write,
				  uint64_t *skip, size_t *local_bytes, size_t *local_zeros)
{
	const struct frame *f = &frames[k];
	uint64_t t1;
	size_t n;
	int err;

	if (f->stored) {
		if (src_data != buf)
			memcpy(buf, src_data, f->dsize);
		n = f->dsize;
	} else {
		if (!squashfs_input && f->dsize == max_dsize &&
		    f->csize == zero_frame_size &&
		    memcmp(src_data, zero_frame, zero_frame_size) == 0) {
			(*local_zeros)++;
			*skip += now_ns() - t0;
			return 0;
		}
		n = ZSTD_decompressDCtx(dctx, buf, f->dsize, src_data, f->csize);
	}
	t1 = now_ns();
	*decode += t1 - t0;
	if (ZSTD_isError(n) || n != f->dsize) {
		fail("frame %zu: %s", k, ZSTD_isError(n) ?
		     ZSTD_getErrorName(n) : "decoded to the wrong size");
		return -1;
	}
	if (all_zero(buf, n)) {
		(*local_zeros)++;
		*skip += now_ns() - t1;
		return 0;
	}
	t0 = now_ns();
	*skip += t0 - t1;
	err = pwrite_all(target_fd, buf, n, f->dst);
	*write += now_ns() - t0;
	if (err) {
		fail("write at byte %lld: %s", (long long)f->dst, strerror(-err));
		return -1;
	}
	*local_bytes += n;
	return 0;
}

static void *worker(void *arg)
{
	ZSTD_DCtx *dctx = ZSTD_createDCtx();
	uint8_t *buf = NULL, *cbuf = NULL;
	uint64_t decode = 0, write = 0, skip = 0, t0;
	size_t local_bytes = 0, local_zeros = 0;

	(void)arg;
	if (!dctx || posix_memalign((void **)&buf, ALIGN, max_dsize) ||
	    (stage1_limit > 0 && max_csize > 0 && !(cbuf = malloc(max_csize)))) {
		fail("out of memory");
		goto out;
	}

	/*
	 * Stage 1 (or the entire run when all frames are cached): each worker
	 * pulls batches lock-free and pread()s straight from the page cache.
	 */
	while (!atomic_load(&failed)) {
		size_t base = atomic_fetch_add(&next_frame, frame_batch);
		size_t end = base + frame_batch < stage1_limit ? base + frame_batch : stage1_limit;

		if (base >= stage1_limit)
			break;
		for (size_t idx = base; idx < end && !atomic_load(&failed); idx++) {
			size_t k = order[idx];
			const struct frame *f = &frames[k];
			int err;

			t0 = now_ns();
			if (f->csize == 0) {
				local_zeros++;
				skip += now_ns() - t0;
				continue;
			}
			if (f->stored) {
				err = pread_all(src_fd, buf, f->dsize, (off_t)f->src);
				if (err) {
					fail("frame %zu: read at byte %zu: %s", k, f->src, strerror(-err));
					goto out;
				}
				if (decode_and_write_frame(dctx, buf, buf, k, t0,
							   &decode, &write, &skip,
							   &local_bytes, &local_zeros) < 0)
					goto out;
			} else {
				err = pread_all(src_fd, cbuf, f->csize, (off_t)f->src);
				if (err) {
					fail("frame %zu: read at byte %zu: %s", k, f->src, strerror(-err));
					goto out;
				}
				if (decode_and_write_frame(dctx, buf, cbuf, k, t0,
							   &decode, &write, &skip,
							   &local_bytes, &local_zeros) < 0)
					goto out;
			}
		}
	}

	/*
	 * Stage 2 (only when cached_frames < nframes): wait for all workers to
	 * drain Stage 1, drop Stage 1's page cache once, then consume uncached
	 * frames fed by the single sequential reader thread.
	 */
	if (uncached_mode && !atomic_load(&failed)) {
		if (cached_frames > 0) {
			pthread_mutex_lock(&stage_mu);
			while (!workers_ready && !atomic_load(&failed))
				pthread_cond_wait(&stage_cv, &stage_mu);
			stage1_done++;
			if (stage1_done >= expected_workers && !stage2_start) {
				if (!atomic_load(&failed)) {
					posix_fadvise(src_fd, 0, 0, POSIX_FADV_DONTNEED);
					posix_fadvise(src_fd, 0, 0, POSIX_FADV_SEQUENTIAL);
				}
				stage2_start = 1;
				pthread_cond_broadcast(&stage_cv);
			} else {
				while (!stage2_start && !atomic_load(&failed))
					pthread_cond_wait(&stage_cv, &stage_mu);
			}
			pthread_mutex_unlock(&stage_mu);
		}

		while (!atomic_load(&failed)) {
			size_t slot_id, k;
			uint8_t *slot_data;
			const struct frame *f;
			uint64_t t1;
			size_t n;
			int err;

			t0 = now_ns();
			pthread_mutex_lock(&q_mu);
			while (ready_count == 0 && !reader_done && !atomic_load(&failed))
				pthread_cond_wait(&q_not_empty, &q_mu);
			if (atomic_load(&failed) || (ready_count == 0 && reader_done)) {
				pthread_mutex_unlock(&q_mu);
				break;
			}
			slot_id = ready_queue[ready_head];
			ready_head = (ready_head + 1) % ring_cap;
			ready_count--;
			pthread_mutex_unlock(&q_mu);

			atomic_fetch_add(&stage2_taken, 1);
			k = ring_slots[slot_id].frame_idx;
			slot_data = ring_slots[slot_id].data;
			f = &frames[k];

			if (f->stored) {
				memcpy(buf, slot_data, f->dsize);
				n = f->dsize;
			} else if (!squashfs_input && f->dsize == max_dsize &&
				   f->csize == zero_frame_size &&
				   memcmp(slot_data, zero_frame, zero_frame_size) == 0) {
				pthread_mutex_lock(&q_mu);
				free_stack[free_count++] = slot_id;
				pthread_cond_signal(&q_not_full);
				pthread_mutex_unlock(&q_mu);
				local_zeros++;
				skip += now_ns() - t0;
				continue;
			} else {
				n = ZSTD_decompressDCtx(dctx, buf, f->dsize, slot_data, f->csize);
			}

			/* Return the slot before pwrite() so the reader can reuse it immediately. */
			pthread_mutex_lock(&q_mu);
			free_stack[free_count++] = slot_id;
			pthread_cond_signal(&q_not_full);
			pthread_mutex_unlock(&q_mu);

			t1 = now_ns();
			decode += t1 - t0;
			if (ZSTD_isError(n) || n != f->dsize) {
				fail("frame %zu: %s", k, ZSTD_isError(n) ?
				     ZSTD_getErrorName(n) : "decoded to the wrong size");
				goto out;
			}
			if (all_zero(buf, n)) {
				local_zeros++;
				skip += now_ns() - t1;
				continue;
			}
			t0 = now_ns();
			skip += t0 - t1;
			err = pwrite_all(target_fd, buf, n, f->dst);
			write += now_ns() - t0;
			if (err) {
				fail("write at byte %lld: %s", (long long)f->dst, strerror(-err));
				goto out;
			}
			local_bytes += n;
		}
	}
out:
	atomic_fetch_add(&bytes_written, local_bytes);
	atomic_fetch_add(&zero_frames, local_zeros);
	atomic_fetch_add(&decode_ns, decode);
	atomic_fetch_add(&write_ns, write);
	atomic_fetch_add(&skip_ns, skip);
	pthread_mutex_lock(&done_mu);
	done_count++;
	if (done_count >= expected_workers)
		pthread_cond_broadcast(&done_cv);
	pthread_mutex_unlock(&done_mu);
	free(cbuf);
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
	size_t p, end;

	if (f->csize == 0)
		return 1;
	p = f->src / page;
	end = (f->src + f->csize + page - 1) / page;

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

static void plan_order(unsigned char *vec)
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
	} else {
		for (k = 0; k < nframes; k++)
			order[k] = k;
	}
	free(vec);
}

/*
 * With OMARCHY_IMAGE_WRITE_PROGRESS set to a file, "<frames taken> <frames>"
 * goes there four times a second and once more as soon as the workers are done,
 * for the installer's progress bar. Best effort: a sample that cannot be
 * written is skipped, and a reader may see the file empty between two samples.
 *
 * The wait between samples ends when the workers are done. A plain sleep kept
 * the tool alive until its next quarter second after the last frame was
 * written: 0.94 s of writing took 1.00 s on a Dell XPS 16.
 */
static void report_progress(const char *path)
{
	char line[64];
	size_t k, s1;
	int fd, n, done;

	for (;;) {
		struct timespec ts;

		pthread_mutex_lock(&done_mu);
		done = done_count >= expected_workers;
		pthread_mutex_unlock(&done_mu);

		s1 = atomic_load(&next_frame);
		if (s1 > stage1_limit)
			s1 = stage1_limit;
		k = s1 + atomic_load(&stage2_taken);
		n = snprintf(line, sizeof(line), "%zu %zu\n", k < nframes ? k : nframes, nframes);
		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
		if (fd >= 0) {
			if (write(fd, line, n) != n) {
				/* a skipped sample */
			}
			close(fd);
		}
		if (done)
			break;

		clock_gettime(CLOCK_MONOTONIC, &ts);
		ts.tv_nsec += 250000000;
		if (ts.tv_nsec >= 1000000000) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_mutex_lock(&done_mu);
		while (done_count < expected_workers) {
			if (pthread_cond_timedwait(&done_cv, &done_mu, &ts) == ETIMEDOUT)
				break;
		}
		pthread_mutex_unlock(&done_mu);
	}
}

static void init_uncached_ring(int threads)
{
	size_t slot_size = max_csize > 0 ? max_csize : 1;
	size_t cap = (size_t)threads * 4;

	if (cap < 16)
		cap = 16;
	if (cap > MAX_RING_SLOTS)
		cap = MAX_RING_SLOTS;
	if (cap > MAX_RING_BYTES / slot_size) {
		cap = MAX_RING_BYTES / slot_size;
		if (cap < 2)
			cap = 2;
	}
	ring_cap = cap;
	ring_slots = calloc(ring_cap, sizeof(*ring_slots));
	ring_buf = malloc(ring_cap * slot_size);
	free_stack = malloc(ring_cap * sizeof(*free_stack));
	ready_queue = malloc(ring_cap * sizeof(*ready_queue));
	if (!ring_slots || !ring_buf || !free_stack || !ready_queue)
		die(FAILED, "out of memory");
	for (size_t s = 0; s < ring_cap; s++) {
		ring_slots[s].data = ring_buf + s * slot_size;
		free_stack[s] = ring_cap - 1 - s;
	}
	free_count = ring_cap;
	ready_head = 0;
	ready_tail = 0;
	ready_count = 0;
	reader_done = 0;
}

static void free_uncached_ring(void)
{
	free(ring_slots);
	free(ring_buf);
	free(free_stack);
	free(ready_queue);
	ring_slots = NULL;
	ring_buf = NULL;
	free_stack = NULL;
	ready_queue = NULL;
}

static int write_image(const char *path, const char *target, int threads)
{
	pthread_t tid[MAX_THREADS], reader_tid;
	pthread_condattr_t cattr;
	uint64_t t0, t1, t2, t3;
	unsigned char *cached;
	size_t size, batch;
	off_t total;
	int i, started, reader_started = 0;

	t0 = now_ns();
	src_fd = open(path, O_RDONLY | O_CLOEXEC);
	if (src_fd < 0)
		die(REFUSED, "%s: %s", path, strerror(errno));
	image = map_fd(src_fd, path, &size, REFUSED);
	cached = cache_snapshot(size);
	if (squashfs_input) {
		total = squashfs_frames(size);
	} else {
		total = read_seek_table(size);
		encode_zero_frame();
	}
	plan_order(cached);
	/*
	 * Unmap before workers start and read frames with pread() in batches:
	 * faulting a multi-GiB mmap from 16 threads contends on pte_offset_map_lock
	 * (warm) and __filemap_add_folio's xa_lock (cold), shatters cold readahead
	 * into ~9 KiB requests, and leaves ~90 ms of exit_mmap PTE teardown after
	 * the write finishes. Unmapping now touches zero data PTEs.
	 */
	munmap((void *)image, size);
	image = NULL;
	posix_fadvise(src_fd, 0, 0, POSIX_FADV_SEQUENTIAL);

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

	uncached_mode = cached_frames < nframes;
	stage1_limit = uncached_mode ? cached_frames : nframes;
	batch = stage1_limit / ((size_t)threads * MAX_BATCH);
	frame_batch = batch < 1 ? 1 : batch > MAX_BATCH ? MAX_BATCH : batch;

	if (uncached_mode) {
		init_uncached_ring(threads);
		workers_ready = 0;
		stage1_done = 0;
		stage2_start = cached_frames == 0 ? 1 : 0;
	}

	pthread_condattr_init(&cattr);
	pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
	pthread_cond_init(&done_cv, &cattr);
	pthread_condattr_destroy(&cattr);
	done_count = 0;
	expected_workers = threads;

	writing = 1;
	t1 = now_ns();
	for (i = 0; i < threads; i++)
		if (pthread_create(&tid[i], NULL, worker, NULL))
			break;
	if (i == 0) {
		free_uncached_ring();
		die(FAILED, "cannot start a thread");
	}
	started = i;
	if (started < threads) {
		pthread_mutex_lock(&done_mu);
		expected_workers = started;
		if (done_count >= expected_workers)
			pthread_cond_broadcast(&done_cv);
		pthread_mutex_unlock(&done_mu);
	}
	if (uncached_mode) {
		pthread_mutex_lock(&stage_mu);
		workers_ready = 1;
		pthread_cond_broadcast(&stage_cv);
		pthread_mutex_unlock(&stage_mu);
		if (pthread_create(&reader_tid, NULL, reader_thread, NULL) == 0)
			reader_started = 1;
		else
			fail("cannot start reader thread");
	}
	if (getenv("OMARCHY_IMAGE_WRITE_PROGRESS"))
		report_progress(getenv("OMARCHY_IMAGE_WRITE_PROGRESS"));
	while (i--)
		pthread_join(tid[i], NULL);
	if (reader_started)
		pthread_join(reader_tid, NULL);
	free_uncached_ring();
	pthread_cond_destroy(&done_cv);
	close(src_fd);
	t2 = now_ns();
	if (atomic_load(&failed))
		return FAILED;
	if (fsync(target_fd) || close(target_fd))
		die(FAILED, "%s: %s", target, strerror(errno));
	t3 = now_ns();

	fprintf(stderr, "omarchy-image-write: wrote %.2f of %.2f GiB (%zu frames, %zu zero, %zu cached, %d threads) in %.2f s\n",
		atomic_load(&bytes_written) / 1073741824.0, total / 1073741824.0, nframes,
		atomic_load(&zero_frames), cached_frames, started, (t3 - t0) / 1e9);
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
