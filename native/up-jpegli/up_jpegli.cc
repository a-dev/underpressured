// C shim over jpegli: Swift cannot import the C++-flavoured jpegli headers, so the app
// links this plain C API instead. Errors never exit(): they longjmp back to upj_encode.
#include "up_jpegli.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "decode.h"
#include "encode.h"

namespace {

struct UpjErrorMgr {
  jpeg_error_mgr pub;  // must be first
  jmp_buf jump;
};

void ErrorExit(j_common_ptr cinfo) {
  longjmp(reinterpret_cast<UpjErrorMgr*>(cinfo->err)->jump, 1);
}

void OutputMessage(j_common_ptr) {}

// quality >= 0 selects jpegli_set_quality; otherwise `distance` is used.
UpjStatus Encode(const uint8_t* pixels, uint32_t width, uint32_t height, size_t stride,
                 uint32_t components, int quality, float distance, int progressive,
                 const uint8_t* icc, size_t icc_len, uint8_t** out, size_t* out_len) {
  if (out == nullptr || out_len == nullptr) return UPJ_INVALID_ARGUMENT;
  *out = nullptr;
  *out_len = 0;
  if (pixels == nullptr || width == 0 || height == 0 || width > 65535 || height > 65535 ||
      (components != 1 && components != 3) || quality > 100 ||
      (quality < 0 && !(distance >= 0.1f && distance <= 25.0f)) ||
      (icc == nullptr && icc_len != 0) || icc_len > 0xFFFFFFFFu ||
      stride < static_cast<size_t>(width) * components) {
    return UPJ_INVALID_ARGUMENT;
  }

  jpeg_compress_struct cinfo;
  UpjErrorMgr err;
  // Written by jpegli through pointers (address taken), so valid after longjmp.
  unsigned char* mem = nullptr;
  unsigned long mem_size = 0;
  cinfo.err = jpegli_std_error(&err.pub);
  err.pub.error_exit = ErrorExit;
  err.pub.output_message = OutputMessage;

  if (setjmp(err.jump)) {
    jpegli_destroy_compress(&cinfo);
    free(mem);
    return UPJ_ENCODE_FAILED;
  }

  jpegli_create_compress(&cinfo);
  jpegli_mem_dest(&cinfo, &mem, &mem_size);

  cinfo.image_width = width;
  cinfo.image_height = height;
  cinfo.input_components = static_cast<int>(components);
  cinfo.in_color_space = components == 1 ? JCS_GRAYSCALE : JCS_RGB;
  jpegli_set_defaults(&cinfo);
  if (quality >= 0) {
    jpegli_set_quality(&cinfo, quality, TRUE);
  } else {
    jpegli_set_distance(&cinfo, distance, TRUE);
    // Visually lossless target: no chroma subsampling (4:2:0 scored up to 6.0 Butteraugli, 4:4:4 2.3).
    for (int c = 0; c < cinfo.num_components; ++c) {
      cinfo.comp_info[c].h_samp_factor = 1;
      cinfo.comp_info[c].v_samp_factor = 1;
    }
  }
  if (progressive) jpegli_simple_progression(&cinfo);
  jpegli_start_compress(&cinfo, TRUE);
  if (icc != nullptr && icc_len > 0) {
    jpegli_write_icc_profile(&cinfo, icc, static_cast<unsigned int>(icc_len));
  }
  for (uint32_t y = 0; y < height; ++y) {
    JSAMPROW row = const_cast<JSAMPROW>(pixels + static_cast<size_t>(y) * stride);
    jpegli_write_scanlines(&cinfo, &row, 1);
  }
  jpegli_finish_compress(&cinfo);
  jpegli_destroy_compress(&cinfo);

  *out = mem;
  *out_len = mem_size;
  return UPJ_OK;
}

bool HasPrefix(jpeg_saved_marker_ptr m, const char* prefix, size_t len) {
  return m->data_length >= len && memcmp(m->data, prefix, len) == 0;
}

bool IsIcc(jpeg_saved_marker_ptr m) {
  return m->marker == JPEG_APP0 + 2 && HasPrefix(m, "ICC_PROFILE\0", 12);
}

bool IsExif(jpeg_saved_marker_ptr m) {
  return m->marker == JPEG_APP0 + 1 && HasPrefix(m, "Exif\0\0", 6);
}

// Standard XMP only; extended XMP and gain map descriptions are dropped with the gain map.
bool IsKeptXmp(jpeg_saved_marker_ptr m) {
  static const char kXmp[] = "http://ns.adobe.com/xap/1.0/";
  if (m->marker != JPEG_APP0 + 1 || !HasPrefix(m, kXmp, sizeof kXmp)) return false;
  static const char* kGainMap[] = {"hdrgm:", "HDRGainMap", "GContainer"};
  for (const char* needle : kGainMap) {
    if (memmem(m->data, m->data_length, needle, strlen(needle)) != nullptr) return false;
  }
  return true;
}

bool IsIptc(jpeg_saved_marker_ptr m) {
  return m->marker == JPEG_APP0 + 13 && HasPrefix(m, "Photoshop 3.0\0", 14);
}

// "Exif\0\0" + a big-endian TIFF header with one IFD0 entry: Orientation (SHORT).
void WriteOrientationExif(j_compress_ptr cinfo, uint32_t orientation) {
  const uint8_t exif[] = {
      'E', 'x', 'i', 'f', 0, 0,                        //
      'M', 'M', 0, 42, 0, 0, 0, 8,                     // TIFF header, IFD0 at 8
      0, 1,                                            // 1 entry
      0x01, 0x12, 0, 3, 0, 0, 0, 1,                    // Orientation, SHORT, count 1
      0, static_cast<uint8_t>(orientation), 0, 0,      // value
      0, 0, 0, 0};                                     // no next IFD
  jpegli_write_marker(cinfo, JPEG_APP0 + 1, exif, sizeof exif);
}

// Reads a JPEG's header and coefficients into `src` (created by the caller).
jvirt_barray_ptr* ReadCoefficients(j_decompress_ptr src, const uint8_t* jpeg, size_t len,
                                   bool save_markers) {
  jpegli_mem_src(src, jpeg, static_cast<unsigned long>(len));
  if (save_markers) {
    jpegli_save_markers(src, JPEG_APP0 + 1, 0xFFFF);
    jpegli_save_markers(src, JPEG_APP0 + 2, 0xFFFF);
    jpegli_save_markers(src, JPEG_APP0 + 13, 0xFFFF);
  }
  jpegli_read_header(src, TRUE);
  return jpegli_read_coefficients(src);
}

}  // namespace

extern "C" UpjStatus upj_encode(const uint8_t* pixels, uint32_t width, uint32_t height,
                                size_t stride, uint32_t components, int quality,
                                int progressive, const uint8_t* icc, size_t icc_len,
                                uint8_t** out, size_t* out_len) {
  if (quality < 0) return UPJ_INVALID_ARGUMENT;
  return Encode(pixels, width, height, stride, components, quality, 0, progressive, icc,
                icc_len, out, out_len);
}

extern "C" UpjStatus upj_encode_distance(const uint8_t* pixels, uint32_t width,
                                         uint32_t height, size_t stride,
                                         uint32_t components, float distance,
                                         int progressive, const uint8_t* icc,
                                         size_t icc_len, uint8_t** out, size_t* out_len) {
  return Encode(pixels, width, height, stride, components, -1, distance, progressive, icc,
                icc_len, out, out_len);
}

extern "C" UpjStatus upj_lossless_rewrite(const uint8_t* jpeg, size_t len, int keep_metadata,
                                          uint32_t orientation, uint8_t** out,
                                          size_t* out_len) {
  if (out == nullptr || out_len == nullptr) return UPJ_INVALID_ARGUMENT;
  *out = nullptr;
  *out_len = 0;
  if (jpeg == nullptr || len == 0 || len > 0xFFFFFFFFu) return UPJ_INVALID_ARGUMENT;

  jpeg_decompress_struct src;
  jpeg_compress_struct dst;
  UpjErrorMgr src_err;
  UpjErrorMgr dst_err;
  unsigned char* mem = nullptr;
  unsigned long mem_size = 0;
  // 0: nothing created, 1: src created, 2: both created. volatile: read after longjmp.
  volatile int created = 0;
  volatile UpjStatus failure = UPJ_DECODE_FAILED;
  src.err = jpegli_std_error(&src_err.pub);
  src_err.pub.error_exit = ErrorExit;
  src_err.pub.output_message = OutputMessage;
  dst.err = jpegli_std_error(&dst_err.pub);
  dst_err.pub.error_exit = ErrorExit;
  dst_err.pub.output_message = OutputMessage;

  if (setjmp(src_err.jump) || setjmp(dst_err.jump)) {
    if (created >= 2) jpegli_destroy_compress(&dst);
    if (created >= 1) jpegli_destroy_decompress(&src);
    free(mem);
    return failure;
  }

  jpegli_create_decompress(&src);
  created = 1;
  jvirt_barray_ptr* coefficients = ReadCoefficients(&src, jpeg, len, true);

  failure = UPJ_ENCODE_FAILED;
  jpegli_create_compress(&dst);
  created = 2;
  jpegli_mem_dest(&dst, &mem, &mem_size);
  jpegli_copy_critical_parameters(&src, &dst);
  dst.optimize_coding = TRUE;
  jpegli_simple_progression(&dst);
  jpegli_write_coefficients(&dst, coefficients);

  if (!keep_metadata && orientation >= 2 && orientation <= 8) {
    WriteOrientationExif(&dst, orientation);
  }
  for (jpeg_saved_marker_ptr m = src.marker_list; m != nullptr; m = m->next) {
    bool keep = IsIcc(m) || (keep_metadata && (IsExif(m) || IsKeptXmp(m) || IsIptc(m)));
    if (keep) jpegli_write_marker(&dst, m->marker, m->data, m->data_length);
  }

  jpegli_finish_compress(&dst);
  jpegli_finish_decompress(&src);
  jpegli_destroy_compress(&dst);
  jpegli_destroy_decompress(&src);

  *out = mem;
  *out_len = mem_size;
  return UPJ_OK;
}

extern "C" UpjStatus upj_coefficients_equal(const uint8_t* a, size_t a_len, const uint8_t* b,
                                            size_t b_len, int* equal) {
  if (equal == nullptr) return UPJ_INVALID_ARGUMENT;
  *equal = 0;
  if (a == nullptr || b == nullptr || a_len == 0 || b_len == 0 || a_len > 0xFFFFFFFFu ||
      b_len > 0xFFFFFFFFu) {
    return UPJ_INVALID_ARGUMENT;
  }

  jpeg_decompress_struct da;
  jpeg_decompress_struct db;
  UpjErrorMgr err;
  volatile int created = 0;
  da.err = jpegli_std_error(&err.pub);
  db.err = &err.pub;
  err.pub.error_exit = ErrorExit;
  err.pub.output_message = OutputMessage;

  if (setjmp(err.jump)) {
    if (created >= 2) jpegli_destroy_decompress(&db);
    if (created >= 1) jpegli_destroy_decompress(&da);
    return UPJ_DECODE_FAILED;
  }

  jpegli_create_decompress(&da);
  created = 1;
  jpegli_create_decompress(&db);
  created = 2;
  jvirt_barray_ptr* ca = ReadCoefficients(&da, a, a_len, false);
  jvirt_barray_ptr* cb = ReadCoefficients(&db, b, b_len, false);

  bool same = da.image_width == db.image_width && da.image_height == db.image_height &&
              da.num_components == db.num_components &&
              da.jpeg_color_space == db.jpeg_color_space;
  for (int c = 0; same && c < da.num_components; ++c) {
    const jpeg_component_info& ia = da.comp_info[c];
    const jpeg_component_info& ib = db.comp_info[c];
    same = ia.h_samp_factor == ib.h_samp_factor && ia.v_samp_factor == ib.v_samp_factor &&
           ia.width_in_blocks == ib.width_in_blocks &&
           ia.height_in_blocks == ib.height_in_blocks && ia.quant_table != nullptr &&
           ib.quant_table != nullptr &&
           memcmp(ia.quant_table->quantval, ib.quant_table->quantval,
                  sizeof ia.quant_table->quantval) == 0;
    for (JDIMENSION row = 0; same && row < ia.height_in_blocks; ++row) {
      JBLOCKARRAY ra = (*da.mem->access_virt_barray)(reinterpret_cast<j_common_ptr>(&da),
                                                    ca[c], row, 1, FALSE);
      JBLOCKARRAY rb = (*db.mem->access_virt_barray)(reinterpret_cast<j_common_ptr>(&db),
                                                    cb[c], row, 1, FALSE);
      same = memcmp(ra[0], rb[0], sizeof(JBLOCK) * ia.width_in_blocks) == 0;
    }
  }

  jpegli_destroy_decompress(&db);
  jpegli_destroy_decompress(&da);
  *equal = same ? 1 : 0;
  return UPJ_OK;
}

extern "C" void upj_buffer_free(uint8_t* data) { free(data); }
