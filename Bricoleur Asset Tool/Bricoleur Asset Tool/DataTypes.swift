//
//  DataTypes.swift
//  Bricoleur Asset Tool
//
//  Created by Sean Hickey on 11/2/18.
//  Copyright © 2018 Massachusetts Institute of Technology. All rights reserved.
//

import Cocoa

typealias U8  = UInt8
typealias U16 = UInt16
typealias U32 = UInt32
typealias U64 = UInt64

typealias S8  = Int8
typealias S16 = Int16
typealias S32 = Int32
typealias S64 = Int64

typealias F32 = Float
typealias F64 = Double

typealias RawPtr = UnsafeMutableRawPointer
typealias Ptr<T> = UnsafeMutablePointer<T>

typealias U8Ptr  = UnsafeMutablePointer<UInt8>
typealias U16Ptr = UnsafeMutablePointer<UInt16>
typealias U32Ptr = UnsafeMutablePointer<UInt32>
typealias U64Ptr = UnsafeMutablePointer<UInt64>

typealias S8Ptr  = UnsafeMutablePointer<Int8>
typealias S16Ptr = UnsafeMutablePointer<Int16>
typealias S32Ptr = UnsafeMutablePointer<Int32>
typealias S64Ptr = UnsafeMutablePointer<Int64>

typealias F32Ptr = UnsafeMutablePointer<Float>
typealias F64Ptr = UnsafeMutablePointer<Double>

extension Int {
    var u8 :  U8 { get {return  U8(self)} }
    var u16 : U16 { get {return U16(self)} }
    var u32 : U32 { get {return U32(self)} }
    var u64 : U64 { get {return U64(self)} }
    
    var  s8 :  S8 { get {return  S8(self)} }
    var s16 : S16 { get {return S16(self)} }
    var s32 : S32 { get {return S32(self)} }
    var s64 : S64 { get {return S64(self)} }
    
    var kilobytes : Int { get { return self * 1024 }}
    var megabytes : Int { get { return self * 1024 * 1024 }}
    var gigabytes : Int { get { return self * 1024 * 1024 * 1024 }}
}

extension Data {
    var bytes : RawPtr {
        return RawPtr(mutating: (self as NSData).bytes)
    }
}

typealias FrameOffset = U32
typealias FrameLength = U32
typealias AssetId = String
typealias ClipId = AssetId
typealias SoundId = AssetId


let VIDEO_FILE_MAGIC_NUMBER : U32 = 0x000F1DE0


/*******************************************************************
 *
 * Clip
 *
 *******************************************************************/


struct FrameInfo {
    let offset : FrameOffset
    let length : FrameLength
}

class Clip {
    
    // Total frames in the clip
    var frames : U32 = 0
    
    // Width of each image
    var width : U32 = 0
    
    // Height of each image
    var height : U32 = 0
    
    // Array of tuples containing each frame offset and length.
    //   Offsets are calculated from the base of the data bytes pointer
    var offsets : [FrameInfo] = []
    
    // JPEG compositing mask data
    var mask : Data = Data()
    
    // JPEG frame data bytes
    var data : Data = Data(capacity: 10.megabytes)
    
    init() {} 
}


func appendFrame(_ clip: Clip, jpegData: U8Ptr, length: Int) {
    let offset = clip.data.count
    clip.data.append(jpegData, count: length)
    clip.offsets.append(FrameInfo(offset: offset.u32, length: length.u32))
    clip.frames += 1
}

func serializeClip(_ clip: Clip) -> Data {
    var out = Data()
    
    // U32 -> Magic Number
    var magic : U32 = VIDEO_FILE_MAGIC_NUMBER
    withUnsafeBytes(of: &magic) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Total frames in clip
    var frames = clip.frames
    withUnsafeBytes(of: &frames) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Width of each image
    var width = clip.width
    withUnsafeBytes(of: &width) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Height of each image
    var height = clip.height
    withUnsafeBytes(of: &height) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Mask data offset from top of file (32 bytes for the header + length of frame offset data)
    var maskOffset : U32 = U32(8 * MemoryLayout<U32>.size + (Int(frames) * MemoryLayout<U32>.size))
    withUnsafeBytes(of: &maskOffset) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Mask length in bytes
    var maskLength = clip.mask.count.u32
    withUnsafeBytes(of: &maskLength) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Data offset from top of file
    var dataOffset : U32 = maskOffset + maskLength
    withUnsafeBytes(of: &dataOffset) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Data length in bytes starting from data pointer
    var dataLength = clip.data.count.u32
    withUnsafeBytes(of: &dataLength) { (ptr) in
        let bytes = ptr.bindMemory(to: U8.self)
        out.append(bytes)
    }
    
    // U32 -> Frame offsets from top of data pointer
    let offsets = clip.offsets.map { $0.offset } // Grab just the offsets, disregard lengths
    for offset in offsets {
        var mutableOffset = offset
        withUnsafeBytes(of: &mutableOffset) { (ptr) in
            let bytes = ptr.bindMemory(to: U8.self)
            out.append(bytes)
        }
    }
    
    out.reserveCapacity(clip.mask.count + clip.data.count)
    out.append(clip.mask)
    out.append(clip.data)
    
    return out
}


func deserializeClip(_ data: Data) -> Clip {
    var frames : U32 = 0
    var width : U32 = 0
    var height : U32 = 0
    var maskOffset : U32 = 0
    var maskLength : U32 = 0
    var dataOffset : U32 = 0
    var dataLength : U32 = 0
    
    let clip = Clip()
    
    data.withUnsafeBytes { (bytes : UnsafePointer<U8>) in
        
        // Parse the first 8 fields of the header
        bytes.withMemoryRebound(to: U32.self, capacity: 8, { (ptr) in
            assert(ptr[0] == VIDEO_FILE_MAGIC_NUMBER)
            frames = ptr[1]
            width = ptr[2]
            height = ptr[3]
            maskOffset = ptr[4]
            maskLength = ptr[5]
            dataOffset = ptr[6]
            dataLength = ptr[7]
        })
        
        
        // Calculate frame offset tuples
        let headerLength = Int(maskOffset)
        bytes.withMemoryRebound(to: U32.self, capacity: headerLength, { (ptr) in
            
            for i in 0..<(frames - 1) { // Handle the last frame differently since we need to use the data length
                // to calculate the frame length
                let thisOffset = ptr[Int(8 + i)]
                let nextOffset = ptr[Int(8 + i + 1)]
                let thisLength = nextOffset - thisOffset
                clip.offsets.append(FrameInfo(offset: thisOffset, length: thisLength))
            }
            
            // Last frame
            let lastOffset = ptr[Int(8 + (frames - 1))]
            let lastLength = dataLength - lastOffset
            clip.offsets.append(FrameInfo(offset: lastOffset, length: lastLength))
        })
        
    }
    
    clip.frames = frames
    clip.width = width
    clip.height = height
    
    let maskDataStart = data.startIndex.advanced(by: Int(maskOffset))
    clip.mask = data.subdata(in: maskDataStart..<(maskDataStart + Int(maskLength))) 
    
    let jpegDataStart = data.startIndex.advanced(by: Int(dataOffset))
    clip.data = data.subdata(in: jpegDataStart..<data.endIndex)
    
    return clip
}


func saveClip(_ clip: Clip, to url: URL) {
    let clipData = serializeClip(clip)
    // @TODO: Handle file writing error
    try! clipData.write(to: url)
}

func loadClip(from url: URL) -> Clip {
    let serialized = try! Data(contentsOf: url)
    return deserializeClip(serialized)
}

func clipImage(clip: Clip, atFrame: Int) -> NSImage {
    let info = clip.offsets[atFrame]
    let frameImageStart = clip.data.startIndex.advanced(by: Int(info.offset))
    let frameData = clip.data.subdata(in: frameImageStart..<(frameImageStart + Int(info.length)))
    return NSImage(data: frameData)!
}


///*******************************************************************
// *
// * Sound
// *
// *******************************************************************/
//
//class Sound {
//    
//    var samples : Data
//    let bytesPerSample : Int
//    var markers : [Int] = []
//    
//    init(id newId: UUID, project newProject: Project, markers newMarkers: [Int]) {
//        id = newId
//        project = newProject
//        samples = Data()
//        bytesPerSample = 2 // @TODO: This is contrived. Do we even really need to keep this property?
//        markers = newMarkers
//    }
//    
//    init(bytesPerSample newBytesPerSample: Int) {
//        id = UUID()
//        bytesPerSample = newBytesPerSample
//        samples = Data()
//    }
//    
//    var length : Int {
//        return samples.count / bytesPerSample
//    }
//}
//
//func saveSound(_ sound: Sound) {
//    try! sound.samples.write(to: sound.assetUrl)
//}
//
//func loadSound(_ id: String, _ project: Project, _ markers: [Int]) {
//    let uuid = UUID(uuidString: id)!
//    
//    let sound = Sound(id: uuid, project: project, markers: markers)
//    let soundData = try! Data(contentsOf: sound.assetUrl)
//    sound.samples = soundData
//    
//    addSoundToProject(sound, project)
//}
//
//
