package com.margelo.nitro.inksignpdf

import android.content.Context
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import java.lang.ref.WeakReference
import kotlinx.coroutines.Deferred

internal fun <T> Deferred<T>.asNitroPromise(): Promise<T> = Promise.async { await() }

@DoNotStrip
class HybridInkSignDocumentFactory : HybridInkSignDocumentFactorySpec() {
  override fun createDocument(options: DocumentOptions?): HybridInkSignDocumentSpec {
    val context = checkNotNull(NitroModules.applicationContext) { "React Native context is unavailable" }
    val core = DocumentCore(context, recordHistory = options?.recordHistory ?: true,
      exportOwnership = ExportOwnership.CALLER, fallbackFontSource = options?.androidFallbackFont)
    core.initialize(options)
    return HybridInkSignDocument(core)
  }
}

/** Nitro adapter; document state, work ordering, and cleanup belong to DocumentCore. */
@DoNotStrip
internal class HybridInkSignDocument(internal val core: DocumentCore) : HybridInkSignDocumentSpec() {
  constructor(context: Context, recordHistory: Boolean = true) : this(
    DocumentCore(context, recordHistory = recordHistory, exportOwnership = ExportOwnership.CALLER))
  private var closePromise: Promise<Unit>? = null

  private fun <T> command(work: suspend () -> T): Promise<T> =
    try { core.submit(work).asNitroPromise() }
    catch (error: Throwable) { Promise<T>().also { it.reject(error) } }

  override val pageCount: Double get() = core.documentInfo().pageCount
  override fun getState(): DocumentState = core.documentInfo()
  override fun getPage(index: PageQuery): Promise<HybridDocumentPageSpec> = command {
    HybridDocumentPage(core, index.match({ core.getPage(it) }, { core.getPage(it) }))
  }
  override fun getPageIdsByTag(tag: String): Array<String> = core.getPageIdsByTag(tag)
  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = command { core.fonts.load(fonts) }
  override fun addPages(options: DocumentAddPagesOptions?): Promise<DocumentAddPagesResult> = command {
    val dimensions = options?.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: (if (core.state.hasDocument) core.state.pageMetadata(0).dimensions else null) ?: PdfPageDimensions(595.28, 841.89)
    val added = core.addPages(options, dimensions)
    DocumentAddPagesResult(added.toDouble(), core.state.pageCount.toDouble())
  }
  override fun removePage(index: Double): Promise<Unit> = command { core.removePage(index) }
  override fun movePage(fromIndex: Double, toIndex: Double): Promise<Unit> = command { core.movePage(fromIndex, toIndex) }
  override fun rotatePage(index: Double, degrees: Double): Promise<Unit> = command { core.rotatePage(index, degrees) }
  override fun finalize(): Promise<String> = command { core.finalize() }
  override fun close(): Promise<Unit> = synchronized(this) {
    closePromise ?: core.close().asNitroPromise().also { closePromise = it }
  }
  override fun dispose() { core.close(cancelPending = true) }
}

@DoNotStrip
internal class HybridDocumentPage(internal val core: DocumentCore, context: PreparedPage,
  owner: HybridInkSignView? = null, internal val modeSession: ModeSessionToken? = null,
) : HybridDocumentPageSpec() {
  private val authorizationOwner = owner?.let(::WeakReference)
  private val prepared = WeakReference(context)
  internal val context: PreparedPage get() = prepared.get()
    ?: throw PdfSessionException("operation_cancelled", "The prepared page was released")
  private fun <T> withPageAccess(action: (DocumentCore) -> T): T = core.withDocument {
    modeSession?.let { token ->
      val owner = authorizationOwner?.get()
      if (owner == null || !owner.isAttachedTo(core)) throw PdfSessionException("operation_cancelled", "The mode session ended")
      owner.requireModeSession(token)
    }
    action(core)
  }
  override fun undo() = withPageAccess { it.undo(context.pageId) }
  override fun redo() = withPageAccess { it.redo(context.pageId) }
  override fun clear() = withPageAccess { it.clearContent(context.pageId) }
  override fun clearInk() = withPageAccess { it.clearInk(context.pageId) }
  override fun getState(): PageInfo = withPageAccess { it.pageInfo(context) }
  override fun resolveInputUnderline(options: ResolveInputUnderlineOptions) = withPageAccess { it.text.resolve(context, options.resolutionOptions()) }
  override fun createInputArea(options: CreateInputAreaOptions) = withPageAccess { it.text.resolve(context, options.resolutionOptions()) }
  override fun getTextValue(id: Double) = withPageAccess { it.text.getValue(context, id) }
  override fun setTextValue(id: Double, text: String, options: TextAnnotationOptions?) = withPageAccess { it.text.setValue(context, id, text, options) }
  override fun setTextOptions(id: Double, options: TextAnnotationOptions) = withPageAccess { it.text.setOptions(context, id, options) }
  override fun adjustTextSize(id: Double, delta: Double) = withPageAccess { it.text.adjustSize(context, id, delta) }
  override fun getInputTarget(id: Double) = withPageAccess { it.text.getEntry(context, id) }
  override fun getInputTargets() = withPageAccess { it.text.getEntries(context) }
}
