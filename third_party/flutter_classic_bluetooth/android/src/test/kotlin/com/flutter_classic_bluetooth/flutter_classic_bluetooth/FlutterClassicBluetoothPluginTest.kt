package com.flutter_classic_bluetooth.flutter_classic_bluetooth

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.ArgumentCaptor
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals

/*
 * Unit tests for the Kotlin portion of the plugin. getPlatformCapabilities is
 * context-independent, so it can be exercised without attaching to an engine.
 *
 * Run with `./gradlew testDebugUnitTest` in `example/android/`, or from an IDE
 * that supports JUnit such as Android Studio.
 */
internal class FlutterClassicBluetoothPluginTest {
    @Test
    fun onMethodCall_getPlatformCapabilities_reportsClassicSupport() {
        val plugin = FlutterClassicBluetoothPlugin()

        val call = MethodCall("getPlatformCapabilities", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        val captor = ArgumentCaptor.forClass(Map::class.java)
        Mockito.verify(mockResult).success(captor.capture())

        val caps = captor.value
        assertEquals(true, caps["canDiscoverDevices"])
        assertEquals(true, caps["canCreateServer"])
        assertEquals(false, caps["requiresMfiCertification"])
    }
}
