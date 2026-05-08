const fs = require('fs')
const path = require('path')
const mc = require(path.join(__dirname, '..', 'prismarinejs', 'node-minecraft-protocol'))

const SEEDS_DIR = path.join(__dirname, '..', 'seeds')

if (!fs.existsSync(SEEDS_DIR)) {
  fs.mkdirSync(SEEDS_DIR, { recursive: true })
}

const client = mc.createClient({
  host: 'localhost',
  port: 25565,
  username: 'SeedBot',
  auth: 'offline',
  version: '1.21.4'
})

const rawBytes = []

// Capture every outgoing framed packet from the start, including handshake/login.
client.framer.on('data', (buffer) => {
  rawBytes.push(Buffer.from(buffer))
})

client.on('state', (newState) => {
  console.log('State:', newState)

  if (newState === 'play') {
    setTimeout(() => {
      console.log('Sending chat...')
      client.chat('Hello from seed generator')

      setTimeout(() => {
        const seedBuffer = Buffer.concat(rawBytes)
        const seedPath = path.join(SEEDS_DIR, 'play-chat.bin')
        fs.writeFileSync(seedPath, seedBuffer)
        console.log('Saved seed:', seedPath, '(' + seedBuffer.length + ' bytes)')
        client.end()
      }, 500)
    }, 500)
  }
})

client.on('error', (err) => {
  console.error('Error:', err.message)
})

client.on('end', () => {
  console.log('Done')
  process.exit(0)
})

setTimeout(() => {
  console.error('Timeout')
  client.end()
  process.exit(1)
}, 15000)
