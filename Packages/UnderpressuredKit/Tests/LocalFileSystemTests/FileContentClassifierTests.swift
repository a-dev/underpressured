import Testing
import UniformTypeIdentifiers
import UnderpressuredCore
@testable import LocalFileSystem

struct FileContentClassifierTests {
    @Test func acceptedFormats() {
        let cases: [(UTType, ImageFormat)] = [
            (.jpeg, .jpeg), (.png, .png), (.heic, .heic), (.heif, .heic),
            (.webP, .webp), (.tiff, .tiff),
            (UTType("public.avif") ?? UTType(importedAs: "public.avif"), .avif),
            (UTType("public.jxl") ?? UTType(importedAs: "public.jxl"), .jpegXL),
        ]
        for (type, format) in cases {
            #expect(FileContentClassifier.classify(type) == .accepted(format))
        }
    }

    @Test func unsupportedImagesRemainDistinctFromOtherFiles() {
        #expect(FileContentClassifier.classify(.gif) == .unsupported(.gif))
        #expect(FileContentClassifier.classify(.rawImage) == .unsupported(.raw))
        #expect(FileContentClassifier.classify(.bmp) == .unsupported(.otherType))
        #expect(FileContentClassifier.classify(.pdf) == .notAnImage)
        #expect(FileContentClassifier.classify(.plainText) == .notAnImage)
        #expect(FileContentClassifier.classify(nil) == .notAnImage)
    }
}
