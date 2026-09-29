// Provided by the benchmark harness. Do not modify.
#include <moonbit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

MOONBIT_FFI_EXPORT moonbit_bytes_t minisql_io_read_stdin(void) {
  size_t cap = 1 << 16, len = 0;
  char *buf = malloc(cap);
  size_t n;
  while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
    len += n;
    if (len == cap) { cap *= 2; buf = realloc(buf, cap); }
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  memcpy(out, buf, len);
  free(buf);
  return out;
}

MOONBIT_FFI_EXPORT void minisql_io_write_stdout(moonbit_bytes_t data) {
  fwrite(data, 1, Moonbit_array_length(data), stdout);
}

MOONBIT_FFI_EXPORT void minisql_io_flush_stdout(void) { fflush(stdout); }

MOONBIT_FFI_EXPORT int32_t minisql_io_file_exists(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  if (!f) return 0;
  fclose(f);
  return 1;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t minisql_io_read_file(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  if (!f) return moonbit_make_bytes(0, 0);
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  size_t got = fread(out, 1, (size_t)len, f);
  (void)got;
  fclose(f);
  return out;
}

MOONBIT_FFI_EXPORT int32_t minisql_io_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  FILE *f = fopen((const char *)path, "wb");
  if (!f) return 0;
  int32_t len = Moonbit_array_length(data);
  size_t put = fwrite(data, 1, (size_t)len, f);
  int ok = fclose(f) == 0 && put == (size_t)len;
  return ok;
}
