#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../aflnet/alloc-inl.h"
#include "../aflnet/aflnet.h"
#include "../aflnet/config.h"

static void compute_and_print_transitions(unsigned int *state_sequence, unsigned int state_count) {
  u32 prev_state = 0;

  printf("state_count=%u\n", state_count);
  printf("states=");
  for (u32 i = 0; i < state_count; i++) {
    printf("%u", state_sequence[i]);
    if (i + 1 < state_count) printf(",");
  }
  printf("\n");

  printf("transitions=\n");
  for (u32 i = 0; i < state_count; i++) {
    u32 cur_state = state_sequence[i];
    u16 map_ptr_idx = (prev_state * STATE_SIZE + cur_state) % SHIFT_SIZE;
    printf("  %u -> %u  idx=%u\n", prev_state, cur_state, map_ptr_idx);
    prev_state = cur_state;
  }
}

static unsigned int* parse_responses_and_print(unsigned char *buf, unsigned int buf_size, unsigned int *state_count_out) {
  init_message_code_map();
  unsigned int *state_sequence = extract_response_codes_minecraft(buf, buf_size, state_count_out);
  compute_and_print_transitions(state_sequence, *state_count_out);
  destroy_message_code_map();
  return state_sequence;
}

static int state_sequences_equal(const unsigned int *a, unsigned int a_count,
                                 const unsigned int *b, unsigned int b_count) {
  if (a_count != b_count) return 0;
  for (unsigned int i = 0; i < a_count; i++) {
    if (a[i] != b[i]) return 0;
  }
  return 1;
}

static unsigned char *read_entire_file(const char *path, unsigned int *size_out) {
  FILE *fp = fopen(path, "rb");
  if (!fp) PFATAL("Unable to open '%s'", path);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (size < 0) PFATAL("Unable to stat '%s'", path);

  unsigned char *buf = ck_alloc((u32) size);
  if (size > 0 && fread(buf, 1, (size_t) size, fp) != (size_t) size) {
    fclose(fp);
    PFATAL("Unable to read '%s'", path);
  }
  fclose(fp);
  *size_out = (u32) size;
  return buf;
}

static int replay_seed_and_collect(const char *seed_path, unsigned char **response_buf_out, unsigned int *response_size_out) {
  unsigned int seed_size = 0;
  unsigned char *seed_buf = read_entire_file(seed_path, &seed_size);
  unsigned int region_count = 0;
  region_t *regions = extract_requests_minecraft(seed_buf, seed_size, &region_count);
  if (region_count == 0) {
    ck_free(seed_buf);
    return 1;
  }

  int sockfd = socket(AF_INET, SOCK_STREAM, 0);
  if (sockfd < 0) PFATAL("Cannot create socket");

  struct timeval timeout;
  timeout.tv_sec = 0;
  timeout.tv_usec = 500000;

  struct sockaddr_in serv_addr;
  memset(&serv_addr, 0, sizeof(serv_addr));
  serv_addr.sin_family = AF_INET;
  serv_addr.sin_port = htons(25565);
  serv_addr.sin_addr.s_addr = inet_addr("127.0.0.1");

  if (connect(sockfd, (struct sockaddr *) &serv_addr, sizeof(serv_addr)) < 0) {
    close(sockfd);
    ck_free(regions);
    ck_free(seed_buf);
    return 2;
  }

  char *response_buf = NULL;
  unsigned int response_size = 0;

  for (unsigned int i = 0; i < region_count; i++) {
    int start = regions[i].start_byte;
    int end = regions[i].end_byte;
    unsigned int len = end - start + 1;
    char *msg = (char *) &seed_buf[start];

    if (net_send(sockfd, timeout, msg, len) != (int) len) {
      close(sockfd);
      ck_free(regions);
      ck_free(seed_buf);
      if (response_buf) ck_free(response_buf);
      return 3;
    }

    if (net_recv(sockfd, timeout, 250, &response_buf, &response_size)) {
      close(sockfd);
      ck_free(regions);
      ck_free(seed_buf);
      if (response_buf) ck_free(response_buf);
      return 4;
    }
  }

  close(sockfd);
  ck_free(regions);
  ck_free(seed_buf);
  *response_buf_out = (unsigned char *) response_buf;
  *response_size_out = response_size;
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--response-file") == 0) {
    unsigned int buf_size = 0;
    unsigned char *buf = read_entire_file(argv[2], &buf_size);

    unsigned int state_count = 0;
    unsigned int *state_sequence = parse_responses_and_print(buf, buf_size, &state_count);

    if (state_count < 2) {
      ck_free(state_sequence);
      ck_free(buf);
      fprintf(stderr, "Expected at least one parsed response state beyond initial 0\n");
      return 2;
    }

    ck_free(state_sequence);
    ck_free(buf);
    return 0;
  }

  if ((argc == 3 || argc == 4) && strcmp(argv[1], "--replay-seed") == 0) {
    unsigned int runs = 1;
    if (argc == 4) runs = (unsigned int) atoi(argv[3]);
    if (runs == 0) runs = 1;

    unsigned int *baseline_sequence = NULL;
    unsigned int baseline_count = 0;

    for (unsigned int run = 1; run <= runs; run++) {
      unsigned char *response_buf = NULL;
      unsigned int response_size = 0;
      int rc = replay_seed_and_collect(argv[2], &response_buf, &response_size);
      if (rc != 0) {
        fprintf(stderr, "Replay failed with code %d on run %u\n", rc, run);
        return rc;
      }

      printf("run=%u response_size=%u\n", run, response_size);
      unsigned int state_count = 0;
      unsigned int *state_sequence = parse_responses_and_print(response_buf, response_size, &state_count);
      ck_free(response_buf);

      if (state_count < 2) {
        ck_free(state_sequence);
        fprintf(stderr, "Expected at least one parsed response state beyond initial 0 after replay\n");
        return 5;
      }

      if (run == 1) {
        baseline_sequence = state_sequence;
        baseline_count = state_count;
      } else {
        if (!state_sequences_equal(baseline_sequence, baseline_count, state_sequence, state_count)) {
          fprintf(stderr, "State sequence mismatch on run %u\n", run);
          ck_free(state_sequence);
          ck_free(baseline_sequence);
          return 6;
        }
        ck_free(state_sequence);
      }
    }

    if (baseline_sequence) ck_free(baseline_sequence);
    printf("Determinism check passed for %u run(s)\n", runs);
    return 0;
  }

  fprintf(stderr, "Usage: %s --response-file <raw_response.bin> | --replay-seed <seed.bin> [runs]\n", argv[0]);
  return 1;
}
