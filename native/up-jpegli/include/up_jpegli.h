#ifndef UP_JPEGLI_H
#define UP_JPEGLI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  UPJ_OK = 0,
  UPJ_INVALID_ARGUMENT = 1,
  UPJ_ENCODE_FAILED = 2,
  UPJ_DECODE_FAILED = 3
} UpjStatus;

/* Encodes 8-bit interleaved pixels (1 = gray, 3 = RGB) to a JPEG held in memory.
 * `stride` is the row pitch in bytes (>= width * components). `quality` is the
 * standard libjpeg 0-100 scale. `icc` may be NULL when `icc_len` is 0.
 * On UPJ_OK the caller owns *out and must release it with upj_buffer_free();
 * on error *out is NULL and *out_len is 0. */
UpjStatus upj_encode(const uint8_t *pixels, uint32_t width, uint32_t height,
                     size_t stride, uint32_t components, int quality,
                     int progressive, const uint8_t *icc, size_t icc_len,
                     uint8_t **out, size_t *out_len);

/* Like upj_encode, but targets a Butteraugli distance (1.0 = visually lossless)
 * through jpegli_set_distance instead of a Quality. `distance` is 0.1-25. */
UpjStatus upj_encode_distance(const uint8_t *pixels, uint32_t width, uint32_t height,
                              size_t stride, uint32_t components, float distance,
                              int progressive, const uint8_t *icc, size_t icc_len,
                              uint8_t **out, size_t *out_len);

/* Lossless JPEG rewrite: copies the DCT coefficients, optimizes the Huffman tables
 * and writes progressive scans. Always keeps the ICC profile (APP2).
 * keep_metadata != 0: also keeps the EXIF APP1, the XMP APP1 (unless it describes an
 * HDR gain map) and the IPTC APP13. keep_metadata == 0: writes a minimal EXIF APP1
 * holding only `orientation` when it is 2-8. Gain map images (MPF) are never kept. */
UpjStatus upj_lossless_rewrite(const uint8_t *jpeg, size_t len, int keep_metadata,
                               uint32_t orientation, uint8_t **out, size_t *out_len);

/* Sets *equal to 1 when both JPEGs have the same dimensions, components, sampling,
 * quantization tables and DCT coefficients, else 0. */
UpjStatus upj_coefficients_equal(const uint8_t *a, size_t a_len, const uint8_t *b,
                                 size_t b_len, int *equal);

/* SSIMULACRA2 score (higher is better, 100 = identical) between two 8-bit sRGB
 * images of the same size, interleaved RGB (components 3) or gray (1). */
UpjStatus upj_ssimulacra2(const uint8_t *reference, size_t reference_stride,
                          const uint8_t *distorted, size_t distorted_stride,
                          uint32_t width, uint32_t height, uint32_t components,
                          double *score);

/* Frees a buffer returned by upj_encode, upj_encode_distance or upj_lossless_rewrite.
 * NULL is a no-op. */
void upj_buffer_free(uint8_t *data);

#ifdef __cplusplus
}
#endif

#endif /* UP_JPEGLI_H */
