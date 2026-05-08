const fs = require('fs')
const path = require('path')
const mc = require(path.join(__dirname, '..', 'prismarinejs', 'node-minecraft-protocol'))

const SEEDS_DIR = path.join(__dirname, '..', 'seeds')
if (!fs.existsSync(SEEDS_DIR)) fs.mkdirSync(SEEDS_DIR, { recursive: true })

function generateSeed(options) {
  return new Promise((resolve, reject) => {
    const client = mc.createClient({
      host: 'localhost',
      port: 25565,
      username: options.username || 'SeedBot',
      auth: 'offline',
      version: options.version || '1.21.4'
    })

    const rawBytes = []

    client.framer.on('data', (buffer) => {
      rawBytes.push(Buffer.from(buffer))
    })

    client.on('state', (newState) => {
      if (newState === 'play' && options.chatMessages) {
        setTimeout(() => {
          options.chatMessages.forEach((msg, i) => {
            setTimeout(() => client.chat(msg), i * 200)
          })

          setTimeout(() => {
            const seedBuffer = Buffer.concat(rawBytes)
            const seedPath = path.join(SEEDS_DIR, options.filename)
            fs.writeFileSync(seedPath, seedBuffer)
            console.log('Generated:', options.filename, '(' + seedBuffer.length + ' bytes)')
            client.end()
            resolve(seedBuffer.length)
          }, options.chatMessages.length * 200 + 500)
        }, 500)
      }
    })

    // For non-play states, save after timeout
    if (!options.chatMessages) {
      setTimeout(() => {
        const seedBuffer = Buffer.concat(rawBytes)
        const seedPath = path.join(SEEDS_DIR, options.filename)
        fs.writeFileSync(seedPath, seedBuffer)
        console.log('Generated:', options.filename, '(' + seedBuffer.length + ' bytes)')
        client.end()
        resolve(seedBuffer.length)
      }, options.timeout || 3000)
    }

    client.on('error', (err) => {
      console.error('Error for', options.filename, ':', err.message)
      reject(err)
    })

    client.on('end', () => {
      if (!options.chatMessages) resolve(0)
    })
  })
}

async function main() {
  const variants = [
    { filename: 'handshake-only.bin', timeout: 1500 },
    { filename: 'play-chat-hello.bin', chatMessages: ['Hello'], timeout: 5000 },
    { filename: 'play-chat-multi.bin', chatMessages: ['Hi', 'How are you?', '/help'], timeout: 5000 },
    { filename: 'play-command-help.bin', chatMessages: ['/help'], timeout: 5000 },
    { filename: 'long-username.bin', username: 'VeryLongUserName123', chatMessages: ['test'], timeout: 5000 },
  ]

  for (const variant of variants) {
    try {
      await generateSeed(variant)
    } catch (err) {
      console.error('Failed:', variant.filename)
    }
    // Small delay between connections
    await new Promise(r => setTimeout(r, 1000))
  }

  console.log('\nAll seeds generated in', SEEDS_DIR)
}

main().catch(console.error)
