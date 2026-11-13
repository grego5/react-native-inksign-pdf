package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class InkStylusSampleFrameTest {
  @Test
  fun androidOrientationBecomesTipToEndRayOnUnrotatedPage() {
    val frame = stylusFrame(identity)

    // Android 0 points the tip up, so the tip-to-end ray points down (+y).
    assertAngle(PI / 2.0, frame.orientation(0.0f))
    assertAngle(0.0, frame.orientation((-PI / 2.0).toFloat()))
    assertAngle(PI, frame.orientation((PI / 2.0).toFloat()))
    assertAngle(3.0 * PI / 2.0, frame.orientation(PI.toFloat()))
    assertAngle(3.0 * PI / 2.0, frame.orientation((-PI).toFloat()))
  }

  @Test
  fun negativeAndroidOrientationsAreAcceptedAsWrappedEngineAngles() {
    val frame = stylusFrame(identity)
    // Values recorded from a Samsung S Pen that the engine previously rejected.
    listOf(-1.9516159f, -1.3898932f, -0.88406926f, -0.05314557f).forEach { value ->
      val orientation = frame.orientation(value)
      assertInEngineRange(orientation)
      assertAngle(value + PI / 2.0, orientation)
    }
  }

  @Test
  fun orientationFollowsPageRotationAndStaysInEngineRange() {
    val displayToView = PageTransform(2.5, 0.0, 0.0, 2.5, -40.0, 12.0)
    for (rotation in 0..3) {
      val rawToView = PageCoordinates(PdfPageDimensions(240.0, 320.0, rotation))
        .rawToView(displayToView)
      val frame = stylusFrame(rawToView.inverse())
      var step = 0
      while (step <= 64) {
        val android = -PI + step * (2.0 * PI / 64.0)
        val orientation = frame.orientation(android.toFloat())
        assertInEngineRange(orientation)
        // Mapping the page ray back to the view yields the view tip-to-end ray.
        val viewX = rawToView.a * cos(orientation) + rawToView.c * sin(orientation)
        val viewY = rawToView.b * cos(orientation) + rawToView.d * sin(orientation)
        val length = kotlin.math.hypot(viewX, viewY)
        assertEquals(-sin(android.toFloat().toDouble()), viewX / length, 1e-5)
        assertEquals(cos(android.toFloat().toDouble()), viewY / length, 1e-5)
        step += 1
      }
    }
  }

  @Test
  fun tiltKeepsAndroidSurfaceNormalConvention() {
    val frame = stylusFrame(identity)

    assertEquals(0.0, frame.tilt(0.0f), epsilon)
    assertEquals(0.7806112, frame.tilt(0.7806112f), 1e-6)
    assertEquals(PI / 2.0, frame.tilt(3.0f), epsilon)
    assertEquals(0.0, frame.tilt(-0.2f), epsilon)
  }

  @Test
  fun availabilityIsFrozenPerContactInsteadOfInferredFromSampleSign() {
    val finger = InkStylusSampleFrame().apply {
      begin(stylus = false, tiltSupported = true, orientationSupported = true, viewToPage = identity)
    }
    assertEquals(-1.0, finger.pressure(1.0f), 0.0)
    assertEquals(-1.0, finger.tilt(0.3f), 0.0)
    assertEquals(-1.0, finger.orientation(-1.0f), 0.0)

    val axisOnlyStylus = InkStylusSampleFrame().apply {
      begin(stylus = true, tiltSupported = false, orientationSupported = false, viewToPage = identity)
    }
    assertEquals(0.25, axisOnlyStylus.pressure(0.25f), epsilon)
    assertEquals(-1.0, axisOnlyStylus.tilt(0.3f), 0.0)
    assertEquals(-1.0, axisOnlyStylus.orientation(-1.0f), 0.0)

    val stylus = stylusFrame(identity)
    assertTrue(stylus.orientation(-3.0f) >= 0.0)
    assertTrue(stylus.pressure(Float.NaN).isNaN())
    assertTrue(stylus.tilt(Float.POSITIVE_INFINITY).isNaN())
    assertTrue(stylus.orientation(Float.NaN).isNaN())
  }

  @Test
  fun onlyFullTurnOrientationRangesAreDirectional() {
    assertTrue(InkStylusSampleFrame.isDirectionalOrientationRange((-PI).toFloat(), PI.toFloat()))
    assertFalse(
      InkStylusSampleFrame.isDirectionalOrientationRange((-PI / 2.0).toFloat(), (PI / 2.0).toFloat()),
    )
    assertFalse(InkStylusSampleFrame.isDirectionalOrientationRange(0.0f, 0.0f))
  }

  @Test
  fun normalizedRadiansProducesHalfOpenFullTurn() {
    assertEquals(0.0, InkStylusSampleFrame.normalizedRadians(2.0 * PI), 0.0)
    assertEquals(0.0, InkStylusSampleFrame.normalizedRadians(-1e-18), 0.0)
    assertEquals(Double.POSITIVE_INFINITY, 1.0 / InkStylusSampleFrame.normalizedRadians(-0.0), 0.0)
    assertEquals(PI, InkStylusSampleFrame.normalizedRadians(-PI), epsilon)
    assertEquals(PI / 2.0, InkStylusSampleFrame.normalizedRadians(5.0 * PI / 2.0), epsilon)
  }

  private fun stylusFrame(viewToPage: PageTransform) = InkStylusSampleFrame().apply {
    begin(stylus = true, tiltSupported = true, orientationSupported = true, viewToPage = viewToPage)
  }

  /** Compares directions on the circle; float inputs may land either side of 0. */
  private fun assertAngle(expected: Double, actual: Double) {
    assertInEngineRange(actual)
    assertEquals(0.0, sin((actual - expected) / 2.0), epsilon)
  }

  private fun assertInEngineRange(value: Double) {
    assertTrue("orientation $value", value >= 0.0 && value < 2.0 * PI)
  }

  private companion object {
    const val epsilon = 1e-6
    val identity = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
  }
}
