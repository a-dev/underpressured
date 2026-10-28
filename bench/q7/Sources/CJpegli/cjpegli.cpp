#include "cjpegli.h"
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "encode.h"

namespace {
struct ErrMgr {
  jpeg_error_mgr pub;
  jmp_buf jb;
};
void on_error(j_common_ptr c) { longjmp(reinterpret_cast<ErrMgr *>(c->err)->jb, 1); }
}  // namespace

int cjpegli_encode_rgbx(const uint8_t *rgbx, int width, int height, size_t row_bytes, int quality,
                        uint8_t **out, size_t *out_size) {
  jpeg_compress_struct cinfo;
  ErrMgr err;
  cinfo.err = jpegli_std_error(&err.pub);
  err.pub.error_exit = on_error;
  unsigned char *buf = nullptr;
  unsigned long size = 0;
  std::vector<uint8_t> row(static_cast<size_t>(width) * 3);
  if (setjmp(err.jb)) {
    jpegli_destroy_compress(&cinfo);
    free(buf);
    return 1;
  }
  jpegli_create_compress(&cinfo);
  jpegli_mem_dest(&cinfo, &buf, &size);
  cinfo.image_width = width;
  cinfo.image_height = height;
  cinfo.input_components = 3;
  cinfo.in_color_space = JCS_RGB;
  jpegli_set_defaults(&cinfo);
  jpegli_set_quality(&cinfo, quality, TRUE);
  jpegli_start_compress(&cinfo, TRUE);
  while (cinfo.next_scanline < cinfo.image_height) {
    const uint8_t *s = rgbx + static_cast<size_t>(cinfo.next_scanline) * row_bytes;
    uint8_t *d = row.data();
    for (int x = 0; x < width; x++) {
      d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
      d += 3; s += 4;
    }
    JSAMPROW rp = row.data();
    jpegli_write_scanlines(&cinfo, &rp, 1);
  }
  jpegli_finish_compress(&cinfo);
  jpegli_destroy_compress(&cinfo);
  *out = buf;
  *out_size = size;
  return 0;
}
