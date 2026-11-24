// Sources/AsyncImageCache/Linux/ImageOrientation.swift
//
// The EXIF orientation of JPEG and TIFF bytes, read from the container without decoding: portable, used by the
// Linux engine (GdkPixbuf applies only these two formats' orientation, so the header size swaps its axes for them)
// and by the Windows engine (WIC applies none, so the decode turns the pixels itself).

extension ImageProcessing {

    // The orientation (1...8) of JPEG or TIFF bytes; 1 for other formats or no valid orientation.
    static func imageOrientation(_ d: UnsafeRawBufferPointer) -> Int {
        return tiffOrientation(d, from: 0, to: d.count) ?? jpegOrientation(d)
    }

    // The EXIF orientation (1...8) of JPEG bytes, from the TIFF IFD0 of the APP1 "Exif" segment; 1 when the
    // bytes are not JPEG or carry no valid orientation. Reads only the segments before the image data.
    static func jpegOrientation(_ d: UnsafeRawBufferPointer) -> Int {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else {
            return 1
        }
        var i = 2
        while i + 4 <= d.count {
            guard d[i] == 0xFF else {
                return 1
            }
            let marker = d[i + 1]
            if marker == 0xFF {   // a fill byte before the marker
                i += 1
                continue
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {   // markers without a length
                i += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 {   // start of scan or end of image: no EXIF before it
                return 1
            }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            let end = i + 2 + length
            guard length >= 2, end <= d.count else {
                return 1
            }
            if marker == 0xE1, let orientation = exifOrientation(d, from: i + 4, to: end) {
                return orientation
            }
            i = end
        }
        return 1
    }

    // The orientation of an APP1 payload "Exif\0\0" + TIFF, or nil.
    private static func exifOrientation(_ d: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Int? {
        let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        guard end - start >= 14, d[start..<(start + 6)].elementsEqual(exifHeader) else {
            return nil
        }
        return tiffOrientation(d, from: start + 6, to: end)
    }

    // The orientation tag (0x0112, a SHORT) of IFD0 in TIFF data at d[tiff..<end] (a TIFF file, or the payload of
    // a JPEG's EXIF segment), or nil when it is not TIFF or has no valid tag.
    private static func tiffOrientation(_ d: UnsafeRawBufferPointer, from tiff: Int, to end: Int) -> Int? {
        guard end - tiff >= 8 else {
            return nil
        }
        let littleEndian: Bool
        if d[tiff] == 0x49, d[tiff + 1] == 0x49 {
            littleEndian = true
        } else if d[tiff] == 0x4D, d[tiff + 1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        func u16(_ o: Int) -> Int? {
            guard o >= tiff, o + 2 <= end else {
                return nil
            }
            return littleEndian ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard let low = u16(littleEndian ? o : o + 2), let high = u16(littleEndian ? o + 2 : o) else {
                return nil
            }
            return high << 16 | low
        }
        guard u16(tiff + 2) == 42, let ifdOffset = u32(tiff + 4), let count = u16(tiff + ifdOffset) else {
            return nil
        }
        for entry in 0..<count {
            let e = tiff + ifdOffset + 2 + entry * 12
            guard let tag = u16(e) else {
                return nil
            }
            if tag == 0x0112 {
                guard u16(e + 2) == 3, let value = u16(e + 8), (1...8).contains(value) else {
                    return nil
                }
                return value
            }
        }
        return nil
    }
}
