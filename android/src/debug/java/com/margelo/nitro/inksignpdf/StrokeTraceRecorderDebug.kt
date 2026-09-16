package com.margelo.nitro.inksignpdf

import java.io.File
import java.io.Writer
import java.util.Locale
import kotlin.math.ceil

private const val ANDROID_STROKE_TRACE_CSV_HEADER =
  "event,time_seconds,page_x,page_y,pressure,tilt,orientation"

internal data class DebugPenConfiguration(
  val minWidth: Double,
  val maxWidth: Double,
  val smoothing: Double,
  val logicalDisplayUnitsPerPageUnit: Double,
)

internal class DebugStrokeTraceSnapshot internal constructor(
  private val eventCodes: ByteArray,
  private val times: DoubleArray,
  private val x: DoubleArray,
  private val y: DoubleArray,
  private val pressure: DoubleArray,
  private val tilt: DoubleArray,
  private val orientation: DoubleArray,
  private val penConfigurations: Array<DebugPenConfiguration?>,
  val size: Int,
  private val presentationSummary: StrokeTracePresentationSummary? = null,
) : StrokeTraceSnapshot {
  fun writeTo(writer: Writer) {
    writer.append(ANDROID_STROKE_TRACE_CSV_HEADER).append('\n')
    for (index in 0 until size) {
      if (index != 0) writer.append('\n')
      penConfigurations[index]?.let {
        writer.append("# pen,")
        appendNumber(writer, it.minWidth)
        writer.append(',')
        appendNumber(writer, it.maxWidth)
        writer.append(',')
        appendNumber(writer, it.smoothing)
        writer.append(',')
        appendNumber(writer, it.logicalDisplayUnitsPerPageUnit)
        writer.append('\n')
      }
      when (eventCodes[index]) {
        DebugStrokeTraceRecorder.EVENT_CANCEL -> writer.append("cancel")
        else -> {
          writer.append(eventName(eventCodes[index]))
          writer.append(',')
          appendNumber(writer, times[index])
          writer.append(',')
          appendNumber(writer, x[index])
          writer.append(',')
          appendNumber(writer, y[index])
          writer.append(',')
          appendNumber(writer, pressure[index])
          writer.append(',')
          appendNumber(writer, tilt[index])
          writer.append(',')
          appendNumber(writer, orientation[index])
        }
      }
    }
    presentationSummary?.let {
      writer.append('\n')
      writer.append(it.csvRow())
    }
    writer.append('\n')
  }

  fun rows(): List<String> {
    val rows = ArrayList<String>(size)
    for (index in 0 until size) {
      if (eventCodes[index] == DebugStrokeTraceRecorder.EVENT_CANCEL) {
        rows += "cancel"
      } else {
        penConfigurations[index]?.let {
          rows += "# pen,%.9f,%.9f,%.9f,%.9f".format(
            Locale.US, it.minWidth, it.maxWidth, it.smoothing,
            it.logicalDisplayUnitsPerPageUnit)
        }
        rows += String.format(
          Locale.US,
          "%s,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f",
          eventName(eventCodes[index]), times[index], x[index], y[index],
          pressure[index], tilt[index], orientation[index],
        )
      }
    }
    return rows
  }

  fun content(): String = buildString {
    writeTo(StringBuilderWriter(this))
  }

  private fun eventName(code: Byte): String = when (code) {
    DebugStrokeTraceRecorder.EVENT_DOWN -> "down"
    DebugStrokeTraceRecorder.EVENT_MOVE -> "move"
    DebugStrokeTraceRecorder.EVENT_UP -> "up"
    else -> error("Unknown trace event code $code")
  }

  private fun appendNumber(writer: Writer, value: Double) {
    writer.append(String.format(Locale.US, "%.9f", value))
  }

  private class StringBuilderWriter(
    private val builder: StringBuilder,
  ) : Writer() {
    override fun write(cbuf: CharArray, off: Int, len: Int) {
      builder.append(cbuf, off, len)
    }
    override fun flush() = Unit
    override fun close() = Unit
  }
}

/** Replayable production-input CSV capture. This implementation is compiled only for debug variants. */
internal class DebugStrokeTraceRecorder(
  private val capacity: Int = DEFAULT_CAPACITY,
) : StrokeTraceRecorder {
  private var eventCodes = ByteArray(minOf(capacity, INITIAL_CAPACITY))
  private var times = DoubleArray(eventCodes.size)
  private var x = DoubleArray(eventCodes.size)
  private var y = DoubleArray(eventCodes.size)
  private var pressure = DoubleArray(eventCodes.size)
  private var tilt = DoubleArray(eventCodes.size)
  private var orientation = DoubleArray(eventCodes.size)
  private var penConfigurations = arrayOfNulls<DebugPenConfiguration>(eventCodes.size)
  private var rowCount = 0
  private var firstTimeSeconds = 0.0
  private var hasFirstTime = false
  private var overflowed = false
  private var presentationSummary: StrokeTracePresentationSummary? = null
  private val inputAgesMillis = LongArray(capacity)
  private var inputAgeCount = 0
  private var pendingPenConfiguration: DebugPenConfiguration? = null

  override var isRecording: Boolean = false
    private set

  init {
    require(capacity > 0)
  }

  override fun start() {
    rowCount = 0
    hasFirstTime = false
    overflowed = false
    presentationSummary = null
    inputAgeCount = 0
    pendingPenConfiguration = null
    isRecording = true
  }

  override fun stop() {
    isRecording = false
  }

  override fun input(
    event: String,
    timeSeconds: Double,
    x: Double,
    y: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
  ) {
    if (!isRecording) return
    val code = when (event) {
      "down" -> EVENT_DOWN
      "move" -> EVENT_MOVE
      "up" -> EVENT_UP
      else -> error("Unknown trace event $event")
    }
    if (!timeSeconds.isFinite() || !x.isFinite() || !y.isFinite()) return
    if (!hasFirstTime) {
      firstTimeSeconds = timeSeconds
      hasFirstTime = true
    }
    val rowIndex = append(
      code, timeSeconds - firstTimeSeconds, x, y,
      optionalValue(pressure), optionalValue(tilt), optionalValue(orientation),
    )
    if (rowIndex >= 0 && code == EVENT_DOWN) {
      penConfigurations[rowIndex] = pendingPenConfiguration
      pendingPenConfiguration = null
    }
  }

  override fun penConfiguration(
    minWidth: Double,
    maxWidth: Double,
    smoothing: Double,
    logicalDisplayUnitsPerPageUnit: Double,
  ) {
    if (!isRecording || !minWidth.isFinite() || !maxWidth.isFinite() ||
      !smoothing.isFinite() || !logicalDisplayUnitsPerPageUnit.isFinite() ||
      minWidth <= 0.0 || maxWidth <= 0.0 ||
      logicalDisplayUnitsPerPageUnit <= 0.0
    ) return
    pendingPenConfiguration = DebugPenConfiguration(
      minWidth, maxWidth, smoothing, logicalDisplayUnitsPerPageUnit,
    )
  }

  override fun cancel() {
    append(EVENT_CANCEL, 0.0, 0.0, 0.0, -1.0, -1.0, -1.0)
  }

  override fun recordInputAgeAtDelivery(ageMillis: Long) {
    if (!isRecording || inputAgeCount == inputAgesMillis.size) return
    inputAgesMillis[inputAgeCount] = ageMillis.coerceAtLeast(0L)
    inputAgeCount += 1
  }

  override fun medianInputAgeMillis(): Long = percentileInputAgeMillis(0.50)

  override fun p95InputAgeMillis(): Long = percentileInputAgeMillis(0.95)

  override fun setPresentationSummary(summary: StrokeTracePresentationSummary) {
    if (isRecording) presentationSummary = summary
  }

  override fun snapshotForExport(): StrokeTraceSnapshot {
    check(!isRecording) { "Stop recording before export" }
    check(!overflowed) { "Recording exceeded the $capacity-operation limit; record a shorter trace" }
    check(rowCount > 0) { "No stroke operations have been recorded" }
    return DebugStrokeTraceSnapshot(
      eventCodes.copyOf(rowCount), times.copyOf(rowCount), x.copyOf(rowCount),
      y.copyOf(rowCount), pressure.copyOf(rowCount), tilt.copyOf(rowCount),
      orientation.copyOf(rowCount), penConfigurations.copyOf(rowCount),
      rowCount, presentationSummary,
    )
  }

  companion object {
    internal const val EVENT_DOWN: Byte = 0
    internal const val EVENT_MOVE: Byte = 1
    internal const val EVENT_UP: Byte = 2
    internal const val EVENT_CANCEL: Byte = 3
    private const val DEFAULT_CAPACITY = 50_000
    private const val INITIAL_CAPACITY = 1_024

    fun writeExport(
      output: File,
      snapshot: DebugStrokeTraceSnapshot,
    ): File {
      output.bufferedWriter().use { writer -> snapshot.writeTo(writer) }
      return output
    }
  }

  fun snapshot(): List<String> = (snapshotForExport() as DebugStrokeTraceSnapshot).rows()

  private fun percentileInputAgeMillis(percentile: Double): Long {
    if (inputAgeCount == 0) return 0L
    val sorted = inputAgesMillis.copyOf(inputAgeCount)
    sorted.sort()
    val index = ceil((sorted.size - 1) * percentile).toInt().coerceIn(0, sorted.lastIndex)
    return sorted[index]
  }

  private fun append(
    code: Byte, time: Double, x: Double, y: Double,
    pressure: Double, tilt: Double, orientation: Double,
  ): Int {
    if (!isRecording || overflowed) return -1
    if (rowCount == capacity) {
      overflowed = true
      isRecording = false
      return -1
    }
    ensureCapacity(rowCount + 1)
    eventCodes[rowCount] = code
    times[rowCount] = time
    this.x[rowCount] = x
    this.y[rowCount] = y
    this.pressure[rowCount] = pressure
    this.tilt[rowCount] = tilt
    this.orientation[rowCount] = orientation
    rowCount += 1
    if (rowCount == capacity) isRecording = false
    return rowCount - 1
  }

  private fun ensureCapacity(required: Int) {
    if (eventCodes.size >= required) return
    val next = minOf(capacity, eventCodes.size * 2)
    eventCodes = eventCodes.copyOf(next)
    times = times.copyOf(next)
    x = x.copyOf(next)
    y = y.copyOf(next)
    pressure = pressure.copyOf(next)
    tilt = tilt.copyOf(next)
    orientation = orientation.copyOf(next)
    penConfigurations = penConfigurations.copyOf(next)
  }

  private fun optionalValue(value: Double): Double = value.takeIf { it.isFinite() } ?: -1.0
}

private fun StrokeTracePresentationSummary.csvRow(): String = String.format(
  Locale.US,
  "# summary,front_buffer,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
  eventCount,
  medianInputAgeMillis,
  p95InputAgeMillis,
  dirtyRegionAreaPixels,
  changedGeometryCount,
  copiedGeometryCount,
  submitToCallbackStartDurationNanos,
  offscreenRecordingDurationNanos,
  frontBufferReplacementDurationNanos,
  fullResetCount,
  staleDropCount,
)

internal fun createStrokeTraceRecorder(): StrokeTraceRecorder =
  DebugStrokeTraceRecorder()

internal fun exportStrokeTrace(
  output: File,
  snapshot: StrokeTraceSnapshot,
): File {
  return DebugStrokeTraceRecorder.writeExport(
    output,
    snapshot as? DebugStrokeTraceSnapshot
      ?: error("Debug trace snapshot required for CSV export"),
  )
}
