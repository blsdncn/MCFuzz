/*
 * Copyright (C) 2026 Velocity Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package com.velocitypowered.proxy.fuzz;

import com.velocitypowered.api.network.ProtocolVersion;
import com.velocitypowered.natives.compression.JavaVelocityCompressor;
import com.velocitypowered.natives.compression.VelocityCompressor;
import com.velocitypowered.proxy.protocol.MinecraftPacket;
import com.velocitypowered.proxy.protocol.ProtocolUtils;
import com.velocitypowered.proxy.protocol.StateRegistry;
import com.velocitypowered.proxy.protocol.netty.MinecraftCompressDecoder;
import com.velocitypowered.proxy.protocol.netty.MinecraftDecoder;
import com.velocitypowered.proxy.protocol.netty.MinecraftVarintFrameDecoder;
import com.velocitypowered.proxy.protocol.packet.PluginMessagePacket;
import com.velocitypowered.proxy.protocol.packet.ServerboundCookieResponsePacket;
import com.velocitypowered.proxy.util.except.QuietRuntimeException;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.DecoderException;
import io.netty.handler.codec.EncoderException;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.Deflater;
import net.kyori.adventure.key.InvalidKeyException;
import net.kyori.adventure.key.Key;
import net.kyori.adventure.nbt.BinaryTagIO;

/**
 * Jazzer fuzz target that explores protocol decoding paths without state transitions.
 */
public final class VelocityProtocolStateless {

  private static final int MAX_STEPS = 12;
  private static final int MAX_PACKET_PAYLOAD = 65536;
  private static final int MAX_OPERATION_PAYLOAD = 16384;
  private static final int MAX_CODEC_PAYLOAD = 262144;
  private static final int MAX_COMPRESSED_OUTPUT = 524288;
  private static final String[] ISSUE_CHANNELS = {
      "floodgate:skin",
      "minecraft:brand",
      "bungeecord:main",
      "velocity:player_info"
  };
  private static final ProtocolVersion[] PROTOCOL_VERSIONS = protocolVersions();

  private VelocityProtocolStateless() {
  }

  /**
   * Jazzer entrypoint.
   *
   * @param input fuzzed input data
   */
  public static void fuzzerTestOneInput(byte[] input) {
    if (input.length == 0) {
      return;
    }

    InputCursor cursor = new InputCursor(input);
    ProtocolVersion version = exploreVersion(cursor);
    ProtocolUtils.Direction direction = exploreDirection(cursor);
    int steps = cursor.consumeInt(1, MAX_STEPS);

    for (int i = 0; i < steps; i++) {
      StateRegistry state = exploreStatelessState(cursor);
      exploreRegistry(state, direction, version, cursor);
      exploreProtocolUtils(version, cursor);
      exploreCodecPaths(state, version, cursor);
      direction = exploreDirection(cursor);
      version = exploreVersion(cursor);
    }
  }

  private static StateRegistry exploreStatelessState(InputCursor cursor) {
    return switch (cursor.consumeInt(0, 4)) {
      case 0 -> StateRegistry.HANDSHAKE;
      case 1 -> StateRegistry.STATUS;
      case 2 -> StateRegistry.LOGIN;
      case 3 -> StateRegistry.CONFIG;
      default -> StateRegistry.PLAY;
    };
  }

  private static ProtocolVersion exploreVersion(InputCursor cursor) {
    int versionIndex = cursor.consumeInt(0, PROTOCOL_VERSIONS.length - 1);
    return PROTOCOL_VERSIONS[versionIndex];
  }

  private static ProtocolUtils.Direction exploreDirection(InputCursor cursor) {
    return cursor.consumeBoolean()
        ? ProtocolUtils.Direction.SERVERBOUND
        : ProtocolUtils.Direction.CLIENTBOUND;
  }

  private static void exploreRegistry(
      StateRegistry state,
      ProtocolUtils.Direction direction,
      ProtocolVersion version,
      InputCursor cursor
  ) {
    final StateRegistry.PacketRegistry.ProtocolRegistry registry;
    try {
      registry = state.getProtocolRegistry(direction, version);
    } catch (IllegalArgumentException expected) {
      return;
    }

    MinecraftPacket packet = registry.createPacket(cursor.consumeInt(0, 0x140));
    if (packet == null) {
      return;
    }

    if (isRiskyNbtPacket(packet)) {
      return;
    }

    byte[] payload = cursor.consumeBytes(MAX_PACKET_PAYLOAD);
    ByteBuf input = Unpooled.wrappedBuffer(payload);
    boolean decodeSucceeded;
    try {
      packet.decode(input, direction, version);
      decodeSucceeded = true;
    } catch (DecoderException | IllegalArgumentException | IndexOutOfBoundsException
             | InvalidKeyException | UnsupportedOperationException expected) {
      decodeSucceeded = false;
    } finally {
      input.release();
    }

    if (!decodeSucceeded) {
      return;
    }

    ByteBuf output = Unpooled.buffer();
    try {
      packet.encode(output, direction, version);
      registry.getPacketId(packet);
    } catch (EncoderException | IllegalArgumentException | IndexOutOfBoundsException
             | InvalidKeyException | UnsupportedOperationException expected) {
      // Malformed input can still result in invalid but expected packet states.
    } finally {
      output.release();
    }
  }

  private static void exploreProtocolUtils(ProtocolVersion version, InputCursor cursor) {
    byte[] payload = cursor.consumeBytes(MAX_OPERATION_PAYLOAD);
    ByteBuf input = Unpooled.wrappedBuffer(payload);
    ByteBuf output = Unpooled.buffer();
    try {
      switch (cursor.consumeInt(0, 16)) {
        case 0 -> ProtocolUtils.readVarInt(input);
        case 1 -> ProtocolUtils.readString(input, cursor.consumeInt(1, 256));
        case 2 -> ProtocolUtils.readByteArray(input, cursor.consumeInt(1, 2048));
        case 3 -> ProtocolUtils.readIntegerArray(input);
        case 4 -> ProtocolUtils.readVarIntArray(input);
        case 5 -> ProtocolUtils.readStringWithoutLength(input);
        case 6 -> ProtocolUtils.readExtendedForgeShort(input);
        case 7 -> {
          ByteBuf slice = ProtocolUtils.readRetainedByteBufSlice17(input);
          slice.release();
        }
        case 8 -> ProtocolUtils.readSoundSource(input, version);
        case 9 -> ProtocolUtils.writeVarInt(output, cursor.consumeInt());
        case 10 -> ProtocolUtils.writeString(output, cursor.consumeAsciiString(128));
        case 11 -> ProtocolUtils.readKey(input);
        case 12 -> ProtocolUtils.readByteArray17(input);
        case 13 -> {
          ByteBuf nbtInput = Unpooled.wrappedBuffer(buildSafeNbtPayload(version, cursor, false));
          try {
            ProtocolUtils.readBinaryTag(nbtInput, version, BinaryTagIO.reader());
          } finally {
            nbtInput.release();
          }
        }
        case 14 -> {
          ByteBuf nbtInput = Unpooled.wrappedBuffer(buildSafeNbtPayload(version, cursor, true));
          try {
            ProtocolUtils.readCompoundTag(nbtInput, version, BinaryTagIO.reader());
          } finally {
            nbtInput.release();
          }
        }
        case 15 -> ProtocolUtils.writeKey(output, ProtocolUtils.readKey(input));
        default -> ProtocolUtils.writeByteArray17(cursor.consumeBytes(512), output,
            cursor.consumeBoolean());
      }
    } catch (DecoderException | EncoderException | IllegalArgumentException
             | IndexOutOfBoundsException | UnsupportedOperationException
             | InvalidKeyException expected) {
      // Malformed payloads are expected during fuzzing.
    } finally {
      input.release();
      output.release();
    }
  }

  private static void exploreCodecPaths(StateRegistry state, ProtocolVersion version,
      InputCursor cursor) {
    switch (cursor.consumeInt(0, 2)) {
      case 0 -> exploreFramePipeline(state, version, cursor);
      case 1 -> exploreCompressionDecoder(cursor);
      default -> explorePluginMessageOverflow(version, cursor);
    }
  }

  private static void exploreFramePipeline(StateRegistry state, ProtocolVersion version,
      InputCursor cursor) {
    byte[] packet = buildServerboundPacketForState(state, version, cursor);
    if (packet.length == 0) {
      return;
    }

    ByteBuf framed = Unpooled.buffer();
    framed.writeZero(cursor.consumeInt(0, 4));
    ProtocolUtils.writeVarInt(framed, packet.length);
    framed.writeBytes(packet);

    MinecraftVarintFrameDecoder frameDecoder =
        new MinecraftVarintFrameDecoder(ProtocolUtils.Direction.SERVERBOUND);
    frameDecoder.setState(state);

    MinecraftDecoder packetDecoder = new MinecraftDecoder(ProtocolUtils.Direction.SERVERBOUND);
    packetDecoder.setState(state);
    packetDecoder.setProtocolVersion(version);

    EmbeddedChannel channel = new EmbeddedChannel(frameDecoder, packetDecoder);
    try {
      channel.writeInbound(framed);
    } catch (DecoderException | QuietRuntimeException
             | IllegalArgumentException | IndexOutOfBoundsException expected) {
      // Invalid framed bytes are expected during fuzzing.
    } finally {
      safeRelease(framed);
      channel.finishAndReleaseAll();
    }
  }

  private static void exploreCompressionDecoder(InputCursor cursor) {
    int threshold = cursor.consumeInt(8, 1024);
    int level = cursor.consumeInt(0, 9);

    byte[] base;
    if (cursor.consumeBoolean()) {
      byte[] pattern = cursor.consumeBytes(64);
      if (pattern.length == 0) {
        pattern = "decompression-attack-pattern".getBytes(StandardCharsets.US_ASCII);
      }

      int wantedSize = cursor.consumeBoolean()
          ? (8 * 1024 * 1024) - cursor.consumeInt(64, 2048)
          : cursor.consumeInt(128, 32768);
      base = repeatPattern(pattern, wantedSize);
    } else {
      base = cursor.consumeBytes(MAX_CODEC_PAYLOAD);
      if (base.length == 0) {
        base = "velocity-compress-seed".getBytes(StandardCharsets.US_ASCII);
      }
    }

    byte[] compressed = deflate(base, level);
    if (compressed.length == 0) {
      return;
    }

    int claimedUncompressedSize = cursor.consumeBoolean()
        ? base.length
        : cursor.consumeInt(0, 8 * 1024 * 1024);

    ByteBuf frame = Unpooled.buffer();
    ProtocolUtils.writeVarInt(frame, claimedUncompressedSize);
    frame.writeBytes(compressed);

    VelocityCompressor compressor = JavaVelocityCompressor.FACTORY.create(Deflater.DEFAULT_COMPRESSION);
    MinecraftCompressDecoder decoder = new MinecraftCompressDecoder(threshold, compressor);
    EmbeddedChannel channel = new EmbeddedChannel(decoder);
    try {
      channel.writeInbound(frame);
    } catch (DecoderException | QuietRuntimeException
             | IllegalArgumentException | IndexOutOfBoundsException expected) {
      // Corrupt compressed packets are expected during fuzzing.
    } finally {
      safeRelease(frame);
      channel.finishAndReleaseAll();
    }
  }

  private static void explorePluginMessageOverflow(ProtocolVersion version, InputCursor cursor) {
    final StateRegistry.PacketRegistry.ProtocolRegistry registry;
    try {
      registry = StateRegistry.PLAY.getProtocolRegistry(ProtocolUtils.Direction.SERVERBOUND, version);
    } catch (IllegalArgumentException expected) {
      return;
    }

    int targetLength = cursor.consumeInt(33000, 260000);
    byte[] seed = cursor.consumeBytes(128);
    if (seed.length == 0) {
      seed = "axiom-plugin-overflow".getBytes(StandardCharsets.US_ASCII);
    }
    byte[] largePayload = repeatPattern(seed, targetLength);

    ByteBuf payloadBuf = Unpooled.wrappedBuffer(largePayload);
    PluginMessagePacket pluginPacket = new PluginMessagePacket(issueChannel(cursor), payloadBuf);
    ByteBuf packetBytes = Unpooled.buffer();
    try {
      ProtocolUtils.writeVarInt(packetBytes, registry.getPacketId(pluginPacket));
      pluginPacket.encode(packetBytes, ProtocolUtils.Direction.SERVERBOUND, version);
    } catch (IllegalArgumentException expected) {
      safeRelease(packetBytes);
      safeRelease(pluginPacket);
      return;
    }

    MinecraftDecoder decoder = new MinecraftDecoder(ProtocolUtils.Direction.SERVERBOUND);
    decoder.setState(StateRegistry.PLAY);
    decoder.setProtocolVersion(version);
    EmbeddedChannel channel = new EmbeddedChannel(decoder);
    try {
      channel.writeInbound(packetBytes);
    } catch (DecoderException | QuietRuntimeException | IllegalArgumentException expected) {
      // Oversized packets should be rejected by length sanity checks.
    } finally {
      safeRelease(packetBytes);
      safeRelease(pluginPacket);
      channel.finishAndReleaseAll();
    }
  }

  private static byte[] buildServerboundPacketForState(StateRegistry state, ProtocolVersion version,
      InputCursor cursor) {
    return switch (state) {
      case HANDSHAKE -> buildHandshakePacket(version, cursor);
      case STATUS -> buildStatusPacket(cursor);
      case LOGIN -> buildLoginPacket(version, cursor);
      case CONFIG, PLAY -> buildConfigOrPlayPacket(state, version, cursor);
    };
  }

  private static byte[] buildHandshakePacket(ProtocolVersion version, InputCursor cursor) {
    ByteBuf out = Unpooled.buffer();
    try {
      ProtocolUtils.writeVarInt(out, 0x00);
      ProtocolUtils.writeVarInt(out, version.getProtocol());

      String host = cursor.consumeBoolean()
          ? "some-dynamic-host-name.internal"
          : "127.0.0.1";
      if (cursor.consumeBoolean()) {
        host = issueChannel(cursor) + ".example.net";
      }
      ProtocolUtils.writeString(out, host);
      out.writeShort(cursor.consumeInt(1, 65535));
      ProtocolUtils.writeVarInt(out, cursor.consumeBoolean() ? 1 : 2);

      return toByteArray(out);
    } catch (IllegalArgumentException expected) {
      return new byte[0];
    } finally {
      out.release();
    }
  }

  private static byte[] buildStatusPacket(InputCursor cursor) {
    ByteBuf out = Unpooled.buffer();
    try {
      if (cursor.consumeBoolean()) {
        ProtocolUtils.writeVarInt(out, 0x00);
      } else {
        ProtocolUtils.writeVarInt(out, 0x01);
        out.writeLong(cursor.consumeLong());
      }
      return toByteArray(out);
    } finally {
      out.release();
    }
  }

  private static byte[] buildLoginPacket(ProtocolVersion version, InputCursor cursor) {
    ByteBuf out = Unpooled.buffer();
    try {
      ProtocolUtils.writeVarInt(out, 0x00);
      String username = cursor.consumeAsciiString(16);
      if (username.isEmpty()) {
        username = "VelocityUser";
      }
      ProtocolUtils.writeString(out, username);

      if (version.noLessThan(ProtocolVersion.MINECRAFT_1_19)) {
        if (version.lessThan(ProtocolVersion.MINECRAFT_1_19_3)) {
          out.writeBoolean(false);
        }

        if (version.noLessThan(ProtocolVersion.MINECRAFT_1_20_2)) {
          out.writeLong(cursor.consumeLong());
          out.writeLong(cursor.consumeLong());
        } else if (version.noLessThan(ProtocolVersion.MINECRAFT_1_19_1)) {
          out.writeBoolean(false);
        }
      }

      return toByteArray(out);
    } catch (IllegalArgumentException expected) {
      return new byte[0];
    } finally {
      out.release();
    }
  }

  private static byte[] buildConfigOrPlayPacket(StateRegistry state, ProtocolVersion version,
      InputCursor cursor) {
    final StateRegistry.PacketRegistry.ProtocolRegistry registry;
    try {
      registry = state.getProtocolRegistry(ProtocolUtils.Direction.SERVERBOUND, version);
    } catch (IllegalArgumentException expected) {
      return new byte[0];
    }

    if (version.noLessThan(ProtocolVersion.MINECRAFT_1_20_5) && cursor.consumeBoolean()) {
      ByteBuf out = Unpooled.buffer();
      try {
        ServerboundCookieResponsePacket cookie = new ServerboundCookieResponsePacket(
            Key.key("minecraft:stone", Key.DEFAULT_SEPARATOR),
            cursor.consumeBoolean() ? cursor.consumeBytes(64) : null);
        ProtocolUtils.writeVarInt(out, registry.getPacketId(cookie));
        cookie.encode(out, ProtocolUtils.Direction.SERVERBOUND, version);
        return toByteArray(out);
      } catch (IllegalArgumentException expected) {
        return new byte[0];
      } finally {
        out.release();
      }
    }

    ByteBuf content = Unpooled.wrappedBuffer(cursor.consumeBytes(8192));
    if (!content.isReadable()) {
      content.release();
      content = Unpooled.wrappedBuffer("plugin-message-seed".getBytes(StandardCharsets.US_ASCII));
    }

    PluginMessagePacket pluginPacket = new PluginMessagePacket(issueChannel(cursor), content);
    ByteBuf out = Unpooled.buffer();
    try {
      ProtocolUtils.writeVarInt(out, registry.getPacketId(pluginPacket));
      pluginPacket.encode(out, ProtocolUtils.Direction.SERVERBOUND, version);
      return toByteArray(out);
    } catch (IllegalArgumentException expected) {
      return new byte[0];
    } finally {
      pluginPacket.release();
      out.release();
    }
  }

  private static byte[] repeatPattern(byte[] pattern, int targetLength) {
    int length = Math.max(1, Math.min(targetLength, MAX_CODEC_PAYLOAD));
    byte[] out = new byte[length];
    for (int i = 0; i < out.length; i++) {
      out[i] = pattern[i % pattern.length];
    }
    return out;
  }

  private static byte[] deflate(byte[] data, int level) {
    Deflater deflater = new Deflater(level);
    deflater.setInput(data);
    deflater.finish();

    byte[] tmp = new byte[4096];
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    while (!deflater.finished() && out.size() < MAX_COMPRESSED_OUTPUT) {
      int written = deflater.deflate(tmp);
      if (written == 0) {
        break;
      }
      out.write(tmp, 0, written);
    }
    deflater.end();
    return out.toByteArray();
  }

  private static byte[] toByteArray(ByteBuf buf) {
    byte[] out = new byte[buf.readableBytes()];
    buf.getBytes(buf.readerIndex(), out);
    return out;
  }

  private static String issueChannel(InputCursor cursor) {
    return ISSUE_CHANNELS[cursor.consumeInt(0, ISSUE_CHANNELS.length - 1)];
  }

  private static boolean isRiskyNbtPacket(MinecraftPacket packet) {
    String name = packet.getClass().getName();
    return name.endsWith("JoinGamePacket")
        || name.endsWith("RespawnPacket")
        || name.endsWith("DialogShowPacket");
  }

  private static byte[] buildSafeNbtPayload(ProtocolVersion version, InputCursor cursor,
      boolean rootCompound) {
    ByteBuf buf = Unpooled.buffer();
    try {
      String key = cursor.consumeAsciiString(8);
      if (key.isEmpty()) {
        key = "k";
      }

      String value = cursor.consumeAsciiString(16);
      if (value.isEmpty()) {
        value = "v";
      }

      if (rootCompound) {
        buf.writeByte(10);
        if (version.lessThan(ProtocolVersion.MINECRAFT_1_20_2)) {
          buf.writeShort(0);
        }

        buf.writeByte(8);
        writeNbtString(buf, key);
        writeNbtString(buf, value);

        buf.writeByte(3);
        writeNbtString(buf, "n");
        buf.writeInt(cursor.consumeInt(0, 1000));

        buf.writeByte(0);
      } else {
        buf.writeByte(8);
        if (version.lessThan(ProtocolVersion.MINECRAFT_1_20_2)) {
          buf.writeShort(0);
        }
        writeNbtString(buf, value);
      }

      return toByteArray(buf);
    } finally {
      buf.release();
    }
  }

  private static void writeNbtString(ByteBuf buf, String value) {
    byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
    int length = Math.min(bytes.length, 32767);
    buf.writeShort(length);
    buf.writeBytes(bytes, 0, length);
  }

  private static void safeRelease(ByteBuf buf) {
    if (buf.refCnt() > 0) {
      buf.release();
    }
  }

  private static void safeRelease(PluginMessagePacket packet) {
    if (packet.refCnt() > 0) {
      packet.release();
    }
  }

  private static ProtocolVersion[] protocolVersions() {
    List<ProtocolVersion> versions = new ArrayList<>();
    for (ProtocolVersion version : ProtocolVersion.values()) {
      if (version.isSupported()) {
        versions.add(version);
      }
    }
    return versions.toArray(new ProtocolVersion[0]);
  }

  static final class InputCursor {

    private final byte[] data;
    private int offset;

    InputCursor(byte[] data) {
      this.data = data;
    }

    boolean consumeBoolean() {
      return (consumeByte() & 1) == 1;
    }

    int consumeInt() {
      int value = 0;
      for (int i = 0; i < Integer.BYTES; i++) {
        value = (value << 8) | (consumeByte() & 0xFF);
      }
      return value;
    }

    int consumeInt(int minInclusive, int maxInclusive) {
      if (minInclusive >= maxInclusive) {
        return minInclusive;
      }
      int range = maxInclusive - minInclusive + 1;
      return minInclusive + Math.floorMod(consumeInt(), range);
    }

    long consumeLong() {
      long high = consumeInt() & 0xFFFFFFFFL;
      long low = consumeInt() & 0xFFFFFFFFL;
      return (high << 32) | low;
    }

    byte[] consumeBytes(int maxLength) {
      int clampedMax = Math.max(0, maxLength);
      int lengthHint = consumeInt();
      int remaining = this.data.length - this.offset;
      int max = Math.min(clampedMax, remaining);
      int length = max == 0 ? 0 : Math.floorMod(lengthHint, max + 1);
      byte[] result = new byte[length];
      for (int i = 0; i < length; i++) {
        result[i] = consumeByte();
      }
      return result;
    }

    String consumeAsciiString(int maxLength) {
      byte[] bytes = consumeBytes(maxLength);
      for (int i = 0; i < bytes.length; i++) {
        bytes[i] = (byte) (32 + Math.floorMod(bytes[i], 95));
      }
      return new String(bytes, StandardCharsets.US_ASCII);
    }

    private byte consumeByte() {
      if (offset >= data.length) {
        return 0;
      }
      return data[offset++];
    }
  }
}
