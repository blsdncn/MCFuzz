#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* Minimal defs from AFLNet */
typedef struct {
  int start_byte;
  int end_byte;
  char modifiable;
  unsigned int *state_sequence;
  unsigned int state_count;
} region_t;

static void* ck_alloc(size_t size) {
  void* p = calloc(1, size);
  if (!p) { perror("calloc"); exit(1); }
  return p;
}
static void* ck_realloc(void* p, size_t size) {
  void* np = realloc(p, size);
  if (!np && size > 0) { perror("realloc"); exit(1); }
  return np;
}

/* Copy of read_varint and extract_requests_minecraft from aflnet.c */
static int read_varint(unsigned char* buf, unsigned int buf_size, unsigned int offset, unsigned int* bytes_read)
{
  int value = 0;
  int position = 0;
  unsigned char currentByte;
  *bytes_read = 0;

  while (1) {
    if (offset + *bytes_read >= buf_size) return -1;
    currentByte = buf[offset + *bytes_read];
    *bytes_read = *bytes_read + 1;
    value |= (currentByte & 0x7F) << position;
    if ((currentByte & 0x80) == 0) break;
    position += 7;
    if (position >= 32) return -1;
  }
  return value;
}

region_t* extract_requests_minecraft(unsigned char* buf, unsigned int buf_size, unsigned int* region_count_ref)
{
  unsigned int region_count = 0;
  region_t *regions = NULL;
  unsigned int byte_count = 0;

  while (byte_count < buf_size) {
    unsigned int len_bytes;
    int packet_len = read_varint(buf, buf_size, byte_count, &len_bytes);
    if (packet_len < 0 || len_bytes == 0) break;

    unsigned int packet_start = byte_count;
    unsigned int packet_end = byte_count + len_bytes + packet_len - 1;
    if (packet_end >= buf_size) packet_end = buf_size - 1;

    region_count++;
    regions = (region_t *)ck_realloc(regions, region_count * sizeof(region_t));
    regions[region_count - 1].start_byte = packet_start;
    regions[region_count - 1].end_byte = packet_end;
    regions[region_count - 1].state_sequence = NULL;
    regions[region_count - 1].state_count = 0;

    byte_count = packet_end + 1;
  }

  if ((region_count == 0) && (buf_size > 0)) {
    regions = (region_t *)ck_realloc(regions, sizeof(region_t));
    regions[0].start_byte = 0;
    regions[0].end_byte = buf_size - 1;
    regions[0].state_sequence = NULL;
    regions[0].state_count = 0;
    region_count = 1;
  }

  *region_count_ref = region_count;
  return regions;
}

int main(int argc, char** argv)
{
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <seed_file>\n", argv[0]);
    return 1;
  }

  FILE* fp = fopen(argv[1], "rb");
  if (!fp) {
    perror("fopen");
    return 1;
  }

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);

  unsigned char* buf = (unsigned char*)malloc(size);
  fread(buf, 1, size, fp);
  fclose(fp);

  unsigned int region_count = 0;
  region_t* regions = extract_requests_minecraft(buf, size, &region_count);

  printf("File size: %ld bytes\n", size);
  printf("Regions found: %u\n", region_count);

  assert(region_count > 0);

  for (unsigned int i = 0; i < region_count; i++) {
    printf("Region %u: start=%d, end=%d, size=%d\n",
           i, regions[i].start_byte, regions[i].end_byte,
           regions[i].end_byte - regions[i].start_byte + 1);
    assert(regions[i].start_byte >= 0);
    assert(regions[i].end_byte < size);
    assert(regions[i].end_byte >= regions[i].start_byte);
  }

  printf("PASS: Seed is valid (%u regions)\n", region_count);

  free(regions);
  free(buf);
  return 0;
}
