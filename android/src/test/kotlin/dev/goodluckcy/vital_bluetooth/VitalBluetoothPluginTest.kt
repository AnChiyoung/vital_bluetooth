package dev.goodluckcy.vital_bluetooth

import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.runBlocking
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/*
 * Run with `./gradlew testDebugUnitTest` in example/android, or from
 * Android Studio.
 */
internal class VitalBluetoothPluginTest {
    private val messenger = Mockito.mock(BinaryMessenger::class.java)

    @Test
    fun capabilities_reportEverythingAndroidSupports() {
        val caps = BleHost(BleFlutterApi(messenger)).getCapabilities()

        assertTrue(caps.ble && caps.classic && caps.bonding && caps.connectionPriority && caps.phy)
    }

    @Test
    fun unimplementedCalls_throwUnsupported() {
        val error = assertFailsWith<VitalBluetoothError> {
            runBlocking { BleHost(BleFlutterApi(messenger)).connect("AA:BB", false) }
        }

        assertEquals("unsupported", error.code)
    }
}
