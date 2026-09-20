package com.margelo.nitro.inksignpdf

import android.graphics.Paint
import android.graphics.Path
import android.graphics.RenderNode
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Immutable Android path commands copied from native cubic geometry. */
internal data class InkPathCommand(
  val type: Int,
  val x: Float = 0f,
  val y: Float = 0f,
  val c1x: Float = 0f,
  val c1y: Float = 0f,
  val c2x: Float = 0f,
  val c2y: Float = 0f,
) {
  companion object {
    const val MOVE = 0
    const val LINE = 1
    const val CUBIC = 2
    const val CLOSE = 3
  }
}

/** Exact, detached path data used by front-buffer callbacks, RenderNodes, and export. */
internal data class InkPathData(
  val commands: List<InkPathCommand>,
  val bounds: InkBounds,
) {
  init {
    require(commands.isNotEmpty())
  }

  fun toPath(): Path = Path().apply {
    fillType = Path.FillType.WINDING
    commands.forEach { command ->
      when (command.type) {
        InkPathCommand.MOVE -> moveTo(command.x, command.y)
        InkPathCommand.LINE -> lineTo(command.x, command.y)
        InkPathCommand.CUBIC -> cubicTo(
          command.c1x, command.c1y, command.c2x, command.c2y, command.x, command.y,
        )
        InkPathCommand.CLOSE -> close()
        else -> error("Unknown immutable ink path command: ${command.type}")
      }
    }
  }

  fun recordInto(node: RenderNode, paint: Paint) {
    val left = floor(bounds.left.toDouble()).toInt()
    val top = floor(bounds.top.toDouble()).toInt()
    val right = ceil(bounds.right.toDouble()).toInt()
    val bottom = ceil(bounds.bottom.toDouble()).toInt()
    node.setPosition(left, top, right, bottom)
    val canvas = node.beginRecording(max(1, right - left), max(1, bottom - top))
    try {
      canvas.translate(-left.toFloat(), -top.toFloat())
      canvas.drawPath(toPath(), paint)
    } finally {
      node.endRecording()
    }
  }

  companion object {
    fun fromCommands(commands: List<InkPathCommand>): InkPathData {
      require(commands.isNotEmpty()) { "Cannot snapshot an empty ink path" }
      val copied = commands.toList()
      val bounds = BoundsAccumulator()
      var currentX = 0.0
      var currentY = 0.0
      copied.forEach { command ->
        when (command.type) {
          InkPathCommand.MOVE -> {
            bounds.include(command.x.toDouble(), command.y.toDouble())
            currentX = command.x.toDouble()
            currentY = command.y.toDouble()
          }
          InkPathCommand.LINE -> {
            bounds.include(currentX, currentY)
            bounds.include(command.x.toDouble(), command.y.toDouble())
            currentX = command.x.toDouble()
            currentY = command.y.toDouble()
          }
          InkPathCommand.CUBIC -> {
            bounds.includeCubic(
              currentX, currentY,
              command.c1x.toDouble(), command.c1y.toDouble(),
              command.c2x.toDouble(), command.c2y.toDouble(),
              command.x.toDouble(), command.y.toDouble(),
            )
            currentX = command.x.toDouble()
            currentY = command.y.toDouble()
          }
          InkPathCommand.CLOSE -> Unit
          else -> error("Unknown immutable ink path command: ${command.type}")
        }
      }
      return InkPathData(copied, bounds.value())
    }
  }

  private class BoundsAccumulator {
    private var left = 0.0
    private var top = 0.0
    private var right = 0.0
    private var bottom = 0.0
    private var initialized = false

    fun include(x: Double, y: Double) {
      if (!initialized) {
        left = x; top = y; right = x; bottom = y; initialized = true
      } else {
        left = min(left, x); top = min(top, y)
        right = max(right, x); bottom = max(bottom, y)
      }
    }

    fun includeCubic(
      p0x: Double, p0y: Double,
      c1x: Double, c1y: Double,
      c2x: Double, c2y: Double,
      p3x: Double, p3y: Double,
    ) {
      include(p0x, p0y)
      include(p3x, p3y)
      includeAtRoots(p0x, c1x, c2x, p3x, true)
      includeAtRoots(p0y, c1y, c2y, p3y, false)
    }

    private fun includeAtRoots(p0: Double, c1: Double, c2: Double, p3: Double, xAxis: Boolean) {
      val a = -p0 + 3.0 * c1 - 3.0 * c2 + p3
      val b = 2.0 * (p0 - 2.0 * c1 + c2)
      val c = c1 - p0
      val discriminant = b * b - 4.0 * a * c
      if (a == 0.0) {
        if (b != 0.0) includeRoot(-c / b, p0, c1, c2, p3, xAxis)
      } else if (discriminant >= 0.0) {
        val root = kotlin.math.sqrt(discriminant)
        includeRoot((-b - root) / (2.0 * a), p0, c1, c2, p3, xAxis)
        includeRoot((-b + root) / (2.0 * a), p0, c1, c2, p3, xAxis)
      }
    }

    private fun includeRoot(
      t: Double, p0: Double, c1: Double, c2: Double, p3: Double, xAxis: Boolean,
    ) {
      if (t <= 0.0 || t >= 1.0 || !t.isFinite()) return
      val u = 1.0 - t
      val value = u * u * u * p0 + 3.0 * u * u * t * c1 +
        3.0 * u * t * t * c2 + t * t * t * p3
      if (xAxis) include(value, top) else include(left, value)
    }

    fun value(): InkBounds {
      check(initialized) { "Path bounds are empty" }
      return InkBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
    }
  }
}

/** Combines detached closed subpaths so one stroke is filled once. */
internal fun mergeInkPathData(sources: Iterable<InkPathData>): InkPathData? {
  val commands = ArrayList<InkPathCommand>()
  sources.forEach { commands.addAll(it.commands) }
  return if (commands.isEmpty()) null else InkPathData.fromCommands(commands)
}
