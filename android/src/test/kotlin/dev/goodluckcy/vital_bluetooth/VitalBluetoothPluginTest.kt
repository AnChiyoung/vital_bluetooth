package dev.goodluckcy.vital_bluetooth

import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.runBlocking
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/*
 * Plain JVM tests: Android framework classes aren't available here, so
 * these cover what doesn't need them. Bluetooth behaviour is checked on a
 * phone with the example app.
 *
 * Run with `./gradlew testDebugUnitTest` in example/android, or from
 * Android Studio.
 */
internal class VitalBluetoothPluginTest {
    @Test
    fun errors_followTheContractInPigeonsMessages() {
        // The Dart side reads these details; see pigeons/messages.dart.
        assertEquals(5, gattError(5).details)
        assertEquals("133", connectionFailed("AA", 133).details)
        assertEquals("2a37", attributeNotFound("2a37").details)
        assertEquals("notConnected", notConnected("AA").code)
    }

    @Test
    fun classicCalls_throwUnsupportedUntilImplemented() {
        val messenger = Mockito.mock(BinaryMessenger::class.java)
        val host = ClassicHost(ClassicFlutterApi(messenger))

        val error = assertFailsWith<VitalBluetoothError> {
            runBlocking { host.connect("AA", "00001101-0000-1000-8000-00805f9b34fb", true) }
        }

        assertEquals("unsupported", error.code)
    }
}
