#ifndef CJPEGLI_H
#define CJPEGLI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Encodes tightly-packed-or-strided RGBX (4 B/px, X ignored) to a JPEG in memory at the given
/// libjpeg quality (jpegli_set_quality(q, TRUE)). Returns 0 on success; *out is malloc'd.
int cjpegli_encode_rgbx(const uint8_t *rgbx, int width, int height, size_t row_bytes, int quality,
                        uint8_t **out, size_t *out_size);
#ifdef __cplusplus
}
#endif
#endif
