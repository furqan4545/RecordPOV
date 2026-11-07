package studio.roast.app

import java.io.File
import java.io.RandomAccessFile

/**
 * YouTube's DASH files are fragmented MP4 whose moov declares the full duration although it holds no samples,
 * so the length is counted twice. When the top-level moov has an mvex box, the declared durations of mvhd, every
 * trak's tkhd and every mdia's mdhd are cleared in place; any other file is left untouched (same as iOS).
 * Returns true when the file is fragmented (and was normalized).
 */
internal fun normalizeFragmentedMp4(file:File):Boolean=RandomAccessFile(file,"rw").use {handle->
    val fileSize=handle.length()
    var offset=0L
    while(offset+8<=fileSize) {
        handle.seek(offset)
        val header=ByteArray(16)
        val read=handle.read(header)
        if(read<8)return@use false
        var length=mp4Number(header,0,4)
        var headerLength=8L
        if(length==1L) {
            if(read<16)return@use false
            length=mp4Number(header,8,8)
            headerLength=16
        }else if(length==0L)length=fileSize-offset
        if(length<headerLength||length>fileSize-offset)return@use false
        if(String(header,4,4,Charsets.US_ASCII)!="moov"){offset+=length;continue}
        if(length-headerLength>64L shl 20)return@use false
        val body=ByteArray((length-headerLength).toInt())
        handle.seek(offset+headerLength)
        handle.readFully(body)
        val moov=mp4Boxes(body,0,body.size)
        if(moov.none{it.type=="mvex"})return@use false
        // Content start of every mvhd, tkhd and mdhd; the duration's place depends on the box version.
        val headers=ArrayList<Pair<String,Int>>()
        moov.filter{it.type=="mvhd"}.forEach{headers.add(it.type to it.content)}
        for(trak in moov.filter{it.type=="trak"}) {
            val children=mp4Boxes(body,trak.content,trak.end)
            children.filter{it.type=="tkhd"}.forEach{headers.add(it.type to it.content)}
            for(mdia in children.filter{it.type=="mdia"})
                mp4Boxes(body,mdia.content,mdia.end).filter{it.type=="mdhd"}.forEach{headers.add(it.type to it.content)}
        }
        for((type,content) in headers) {
            if(content>=body.size)return@use false
            val longForm=body[content]==1.toByte()
            val place=content+if(type=="tkhd")(if(longForm)28 else 20)else(if(longForm)24 else 16)
            val size=if(longForm)8 else 4
            if(place+size>body.size)return@use false
            body.fill(0.toByte(),place,place+size)
        }
        handle.seek(offset+headerLength)
        handle.write(body)
        return@use true
    }
    false
}

private class Mp4Box(val type:String,val content:Int,val end:Int)

private fun mp4Boxes(data:ByteArray,start:Int,end:Int):List<Mp4Box> {
    val result=ArrayList<Mp4Box>()
    var position=start
    while(position+8<=end) {
        val length=mp4Number(data,position,4)
        if(length<8||position+length>end)break
        result.add(Mp4Box(String(data,position+4,4,Charsets.US_ASCII),position+8,(position+length).toInt()))
        position+=length.toInt()
    }
    return result
}

private fun mp4Number(data:ByteArray,start:Int,count:Int):Long {
    var value=0L
    for(index in start until start+count)value=(value shl 8) or (data[index].toLong() and 0xff)
    return value
}
