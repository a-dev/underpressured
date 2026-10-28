import Testing
import UnderpressuredCore

@Suite struct OutputFormatTests {
    private let others: [ImageFormat] = [.heic, .webp, .tiff, .avif, .jpegXL]

    @Test func table_spec5_jpegSource() {
        #expect(OutputFormat.original.resolve(for: .jpeg) == .write(.jpeg))
        #expect(OutputFormat.jpeg.resolve(for: .jpeg) == .write(.jpeg))
        #expect(OutputFormat.png.resolve(for: .jpeg) == .write(.png))
    }

    @Test func table_spec5_pngSource() {
        #expect(OutputFormat.original.resolve(for: .png) == .write(.png))
        #expect(OutputFormat.jpeg.resolve(for: .png) == .write(.jpeg))
        #expect(OutputFormat.png.resolve(for: .png) == .write(.png))
    }

    @Test func table_spec5_otherSources() {
        for source in others {
            #expect(OutputFormat.original.resolve(for: source) == .skip(.cantWriteYet(source)))
            #expect(OutputFormat.jpeg.resolve(for: source) == .write(.jpeg))
            #expect(OutputFormat.png.resolve(for: source) == .write(.png))
        }
    }

    @Test func skipReason_spec5_preservesFormatReason() {
        #expect(OutputFormat.original.resolve(for: .heic)
            == .skip(.cantWriteYet(.heic)))
    }

    @Test func flatten_spec5_onlyJPEGOutput() {
        #expect(WritableFormat.jpeg.flattensTransparencyOntoWhite)
        #expect(!WritableFormat.png.flattensTransparencyOntoWhite)
    }

    @Test func extension_spec5_originalKeepsNameAndCase() {
        for name in ["a.jpeg", "a.JPG", "a.JPEG", "a.jpg", "noext"] {
            #expect(outputFileName(sourceFileName: name, source: .jpeg, resolved: .jpeg) == name)
        }
        for name in ["a.PNG", "a.png"] {
            #expect(outputFileName(sourceFileName: name, source: .png, resolved: .png) == name)
        }
    }

    @Test func extension_spec5_conversionsGetJpgOrPng() {
        #expect(outputFileName(sourceFileName: "a.png", source: .png, resolved: .jpeg) == "a.jpg")
        #expect(outputFileName(sourceFileName: "a.JPEG", source: .jpeg, resolved: .png) == "a.png")
        #expect(outputFileName(sourceFileName: "a.HEIC", source: .heic, resolved: .jpeg) == "a.jpg")
        #expect(outputFileName(sourceFileName: "a.webp", source: .webp, resolved: .png) == "a.png")
        #expect(outputFileName(sourceFileName: "a.tif", source: .tiff, resolved: .jpeg) == "a.jpg")
    }

    @Test func extension_spec5_multipleDotsAndNoExtension() {
        #expect(outputFileName(sourceFileName: "a.b.png", source: .png, resolved: .jpeg) == "a.b.jpg")
        #expect(outputFileName(sourceFileName: "photo", source: .heic, resolved: .png) == "photo.png")
        #expect(outputFileName(sourceFileName: ".hidden", source: .heic, resolved: .jpeg) == ".hidden.jpg")
    }
}
