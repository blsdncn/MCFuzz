#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include "alloc-inl.h"
#include "aflnet.h"

#define server_wait_usecs 10000

unsigned int* (*extract_response_codes)(unsigned char* buf, unsigned int buf_size, unsigned int* state_count_ref) = NULL;

#define AFLNET_REPLAY_EXIT_CONNECT_FAILED 1
#define AFLNET_REPLAY_EXIT_TRAILING_SIZE 6
#define AFLNET_REPLAY_EXIT_TRUNCATED_PAYLOAD 7
#define AFLNET_REPLAY_EXIT_NO_RESPONSE 8
#define AFLNET_REPLAY_EXIT_SEND_FAILED 9
#define AFLNET_REPLAY_EXIT_RECV_FAILED 10

static int strict_replay_mode(void) {
  char *strict = getenv("AFLNET_REPLAY_STRICT");
  return strict && strict[0] && strcmp(strict, "0");
}

static int validate_replay_file(FILE *fp) {
  long total_size, offset = 0;

  if (fseek(fp, 0, SEEK_END) != 0) return 0;
  total_size = ftell(fp);
  if (total_size < 0) return 0;
  if (fseek(fp, 0, SEEK_SET) != 0) return 0;

  while (offset < total_size) {
    unsigned int size = 0;
    if (total_size - offset < (long) sizeof(unsigned int)) {
      fprintf(stderr, "[AFLNet-replay] Truncated packet size at offset %ld\n", offset);
      rewind(fp);
      return AFLNET_REPLAY_EXIT_TRAILING_SIZE;
    }
    if (fread(&size, sizeof(unsigned int), 1, fp) != 1) {
      fprintf(stderr, "[AFLNet-replay] Unable to read packet size at offset %ld\n", offset);
      rewind(fp);
      return AFLNET_REPLAY_EXIT_TRAILING_SIZE;
    }
    offset += sizeof(unsigned int);
    if ((long) size > total_size - offset) {
      fprintf(stderr,
              "[AFLNet-replay] Truncated packet payload at offset %ld: declared=%u available=%ld\n",
              offset, size, total_size - offset);
      rewind(fp);
      return AFLNET_REPLAY_EXIT_TRUNCATED_PAYLOAD;
    }
    if (fseek(fp, size, SEEK_CUR) != 0) {
      fprintf(stderr, "[AFLNet-replay] Unable to seek over packet payload at offset %ld\n", offset);
      rewind(fp);
      return AFLNET_REPLAY_EXIT_TRUNCATED_PAYLOAD;
    }
    offset += size;
  }

  rewind(fp);
  return 0;
}

/* Expected arguments:
1. Path to the test case (e.g., crash-triggering input)
2. Application protocol (e.g., RTSP, FTP)
3. Server's network port
Optional:
4. First response timeout (ms), default 1
5. Follow-up responses timeout (us), default 1000
*/

int main(int argc, char* argv[])
{
  FILE *fp;
  int portno, n;
  struct sockaddr_in serv_addr;
  char* buf = NULL, *response_buf = NULL;
  int response_buf_size = 0;
  unsigned int size, i, state_count, packet_count = 0;
  unsigned int *state_sequence;
  unsigned int socket_timeout = 1000;
  unsigned int poll_timeout = 1;
  int strict_mode = strict_replay_mode();


  if (argc < 4) {
    PFATAL("Usage: ./aflnet-replay packet_file protocol port [first_resp_timeout(us) [follow-up_resp_timeout(ms)]]");
  }

  fp = fopen(argv[1],"rb");
  if(fp == NULL){
    fprintf(stderr, "[AFLNet-replay] Error opening file %s\n", argv[1]);
    exit(1);
  }

  int validation_rc = validate_replay_file(fp);
  if (validation_rc != 0) {
    fclose(fp);
    return validation_rc;
  }

  if (!strcmp(argv[2], "RTSP")) extract_response_codes = &extract_response_codes_rtsp;
  else if (!strcmp(argv[2], "FTP")) extract_response_codes = &extract_response_codes_ftp;
  else if (!strcmp(argv[2], "MQTT")) extract_response_codes = &extract_response_codes_mqtt;
  else if (!strcmp(argv[2], "DNS")) extract_response_codes = &extract_response_codes_dns;
  else if (!strcmp(argv[2], "DTLS12")) extract_response_codes = &extract_response_codes_dtls12;
  else if (!strcmp(argv[2], "DICOM")) extract_response_codes = &extract_response_codes_dicom;
  else if (!strcmp(argv[2], "SMTP")) extract_response_codes = &extract_response_codes_smtp;
  else if (!strcmp(argv[2], "SSH")) extract_response_codes = &extract_response_codes_ssh;
  else if (!strcmp(argv[2], "TLS")) extract_response_codes = &extract_response_codes_tls;
  else if (!strcmp(argv[2], "SIP")) extract_response_codes = &extract_response_codes_sip;
  else if (!strcmp(argv[2], "HTTP")) extract_response_codes = &extract_response_codes_http;
  else if (!strcmp(argv[2], "IPP")) extract_response_codes = &extract_response_codes_ipp;
  else if (!strcmp(argv[2], "SNMP")) extract_response_codes = &extract_response_codes_SNMP;
  else if (!strcmp(argv[2], "TFTP")) extract_response_codes = &extract_response_codes_tftp;
  else if (!strcmp(argv[2], "NTP")) extract_response_codes = &extract_response_codes_NTP;
  else if (!strcmp(argv[2], "DHCP")) extract_response_codes = &extract_response_codes_dhcp;
  else if (!strcmp(argv[2], "SNTP")) extract_response_codes = &extract_response_codes_SNTP;
  else if (!strcmp(argv[2], "MC")) extract_response_codes = &extract_response_codes_minecraft;
else {fprintf(stderr, "[AFLNet-replay] Protocol %s has not been supported yet!\n", argv[2]); exit(1);}

  portno = atoi(argv[3]);

  if (argc > 4) {
    poll_timeout = atoi(argv[4]);
    if (argc > 5) {
      socket_timeout = atoi(argv[5]);
    }
  }

  //Wait for the server to initialize
  usleep(server_wait_usecs);

  if (response_buf) {
    ck_free(response_buf);
    response_buf = NULL;
    response_buf_size = 0;
  }

  int sockfd;
  if ((!strcmp(argv[2], "DTLS12")) || (!strcmp(argv[2], "DNS")) || (!strcmp(argv[2], "SIP"))) {
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
  } else {
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
  }

  if (sockfd < 0) {
    PFATAL("Cannot create a socket");
  }

  //Set timeout for socket data sending/receiving -- otherwise it causes a big delay
  //if the server is still alive after processing all the requests
  struct timeval timeout;

  timeout.tv_sec = 0;
  timeout.tv_usec = socket_timeout;

  setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, (char *)&timeout, sizeof(timeout));

  memset(&serv_addr, '0', sizeof(serv_addr));

  serv_addr.sin_family = AF_INET;
  serv_addr.sin_port = htons(portno);
  serv_addr.sin_addr.s_addr = inet_addr("127.0.0.1");

  if(connect(sockfd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
    //If it cannot connect to the server under test
    //try it again as the server initial startup time is varied
    for (n=0; n < 1000; n++) {
      if (connect(sockfd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) == 0) break;
      usleep(1000);
    }
    if (n== 1000) {
      close(sockfd);
      return 1;
    }
  }

  //Send requests one by one
  //And save all the server responses
  while(!feof(fp)) {
    if (buf) {ck_free(buf); buf = NULL;}
    if (fread(&size, sizeof(unsigned int), 1, fp) > 0) {
      packet_count++;
    	fprintf(stderr,"\nSize of the current packet %d is  %d\n", packet_count, size);

      buf = (char *)ck_alloc(size);
      if (size > 0 && fread(buf, size, 1, fp) != 1) {
        fprintf(stderr, "[AFLNet-replay] Truncated packet payload while reading packet %d\n", packet_count);
        fclose(fp);
        close(sockfd);
        if (buf) ck_free(buf);
        if (response_buf) ck_free(response_buf);
        return AFLNET_REPLAY_EXIT_TRUNCATED_PAYLOAD;
      }

      if (net_recv(sockfd, timeout, poll_timeout, &response_buf, &response_buf_size)) {
        fprintf(stderr, "[AFLNet-replay] Receive failed before packet %d\n", packet_count);
        if (strict_mode) {
          fclose(fp);
          close(sockfd);
          if (buf) ck_free(buf);
          if (response_buf) ck_free(response_buf);
          return AFLNET_REPLAY_EXIT_RECV_FAILED;
        }
        break;
      }
      n = net_send(sockfd, timeout, buf,size);
      if (n != size) {
        fprintf(stderr, "[AFLNet-replay] Send failed for packet %d: sent=%d expected=%u\n", packet_count, n, size);
        if (strict_mode) {
          fclose(fp);
          close(sockfd);
          if (buf) ck_free(buf);
          if (response_buf) ck_free(response_buf);
          return AFLNET_REPLAY_EXIT_SEND_FAILED;
        }
        break;
      }

      if (net_recv(sockfd, timeout, poll_timeout, &response_buf, &response_buf_size)) {
        fprintf(stderr, "[AFLNet-replay] Receive failed after packet %d\n", packet_count);
        if (strict_mode) {
          fclose(fp);
          close(sockfd);
          if (buf) ck_free(buf);
          if (response_buf) ck_free(response_buf);
          return AFLNET_REPLAY_EXIT_RECV_FAILED;
        }
        break;
      }
    }
  }

  fclose(fp);
  close(sockfd);

  if (response_buf_size == 0) {
    fprintf(stderr, "[AFLNet-replay] No server response captured\n");
    if (strict_mode) {
      if (buf) ck_free(buf);
      if (response_buf) ck_free(response_buf);
      return AFLNET_REPLAY_EXIT_NO_RESPONSE;
    }
  }

  //Extract response codes
  init_message_code_map();
  state_sequence = (*extract_response_codes)(response_buf, response_buf_size, &state_count);
  destroy_message_code_map();

  fprintf(stderr,"\n--------------------------------");
  fprintf(stderr,"\nResponses from server:");

  for (i = 0; i < state_count; i++) {
    fprintf(stderr,"%d-",state_sequence[i]);
  }

  fprintf(stderr,"\n++++++++++++++++++++++++++++++++\nResponses in details:\n");
  for (i=0; i < response_buf_size; i++) {
    fprintf(stderr,"%c",response_buf[i]);
  }
  fprintf(stderr,"\n--------------------------------");

  //Free memory
  ck_free(state_sequence);
  if (buf) ck_free(buf);
  ck_free(response_buf);

  return 0;
}

