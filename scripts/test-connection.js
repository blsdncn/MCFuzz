const path = require('path')
const mc = require(path.join(__dirname, '..', 'prismarinejs', 'node-minecraft-protocol'))

const client = mc.createClient({
  host: 'localhost',
  port: 25565,
  username: 'TestBot',
  auth: 'offline',
  version: '1.21.4'
})

const statesReached = []

client.on('state', (newState) => {
  statesReached.push(newState)
  if (newState === 'play') {
    console.log('PASS: Reached PLAY state')
    console.log('States:', statesReached.join(' -> '))
    client.end()
    setTimeout(() => process.exit(0), 100)
  }
})

client.on('error', (err) => {
  console.error('ERROR:', err.message)
  process.exit(1)
})

setTimeout(() => {
  console.error('FAIL: Timeout. States:', statesReached)
  process.exit(1)
}, 15000)
