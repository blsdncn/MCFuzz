const fs = require('fs')
const path = require('path')

// Convert raw MC seed (VarInt-length prefixed) to AFLNet replay format (4-byte size prefixed)
function convertSeedToReplayFormat(inputPath, outputPath) {
  const rawSeed = fs.readFileSync(inputPath)
  const output = []
  let offset = 0

  while (offset < rawSeed.length) {
    // Read VarInt length
    let value = 0
    let position = 0
    let lenBytes = 0
    let currentByte

    while (true) {
      if (offset + lenBytes >= rawSeed.length) break
      currentByte = rawSeed[offset + lenBytes]
      lenBytes++
      value |= (currentByte & 0x7F) << position
      if ((currentByte & 0x80) === 0) break
      position += 7
      if (position >= 32) break
    }

    const packetLen = value
    const packetStart = offset
    const packetEnd = offset + lenBytes + packetLen

    if (packetEnd > rawSeed.length) {
      // Partial packet — include rest of buffer
      const remaining = rawSeed.slice(offset)
      const sizeBuf = Buffer.alloc(4)
      sizeBuf.writeUInt32LE(remaining.length, 0)
      output.push(sizeBuf)
      output.push(remaining)
      break
    }

    const packetData = rawSeed.slice(packetStart, packetEnd)
    const sizeBuf = Buffer.alloc(4)
    sizeBuf.writeUInt32LE(packetData.length, 0)
    output.push(sizeBuf)
    output.push(packetData)

    offset = packetEnd
  }

  fs.writeFileSync(outputPath, Buffer.concat(output))
  console.log('Converted', rawSeed.length, 'bytes ->', outputPath)
}

const seedPath = process.argv[2] || path.join(__dirname, '..', 'seeds', 'play-chat.bin')
const replayPath = seedPath.replace('.bin', '-replay.bin')

convertSeedToReplayFormat(seedPath, replayPath)
console.log('Replay file:', replayPath)
