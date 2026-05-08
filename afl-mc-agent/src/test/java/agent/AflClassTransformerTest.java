package agent;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AflClassTransformerTest {

    private static final String EXACT_TITLE_WORKAROUND =
            "com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket";

    @Test
    void exactClassExcludeWinsOverIncludeForGenericTitlePacket() {
        AflClassTransformer transformer = new AflClassTransformer(
                new String[]{"com.velocitypowered.*"},
                new String[]{EXACT_TITLE_WORKAROUND}
        );

        assertFalse(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/GenericTitlePacket"
        ));
    }

    @Test
    void otherTitlePacketClassesStillInstrumentWithExactClassWorkaround() {
        AflClassTransformer transformer = new AflClassTransformer(
                new String[]{"com.velocitypowered.*"},
                new String[]{EXACT_TITLE_WORKAROUND}
        );

        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/LegacyTitlePacket"
        ));
        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/TitleActionbarPacket"
        ));
        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/TitleClearPacket"
        ));
        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/TitleSubtitlePacket"
        ));
        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/TitleTextPacket"
        ));
        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/title/TitleTimesPacket"
        ));
    }

    @Test
    void siblingVelocityPacketOutsideTitleClusterStillInstruments() {
        AflClassTransformer transformer = new AflClassTransformer(
                new String[]{"com.velocitypowered.*"},
                new String[]{EXACT_TITLE_WORKAROUND}
        );

        assertTrue(transformer.shouldInstrument(
                "com/velocitypowered/proxy/protocol/packet/JoinGamePacket"
        ));
    }
}
