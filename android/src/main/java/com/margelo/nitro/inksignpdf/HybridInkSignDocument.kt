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
  override fun openDoc(uri: String, options: DocumentOpenOptions?): Promise<HybridInkSignDocumentSpec> {
    val context = checkNotNull(NitroModules.applicationContext) { "React Native context is unavailable" }
    return HybridInkSignDocument(context).open(uri, options)
  }
}

/** Nitro adapter; document state, work ordering, and cleanup belong to DocumentCore. */
@DoNotStrip
internal class HybridInkSignDocument(context: Context) : HybridInkSignDocumentSpec() {
  private val core = DocumentCore(context, recordHistory = false, exportOwnership = ExportOwnership.CALLER)
  private var closePromise: Promise<Unit>? = null

  internal fun open(uri: String, options: DocumentOpenOptions?): Promise<HybridInkSignDocumentSpec> {
    val opening = core.submit { core.open(uri, options); this@HybridInkSignDocument }
    return Promise.async {
      try { opening.await() }
      catch (error: Throwable) { core.close(cancelPending = true).await(); throw error }
    }
  }

  private fun <T> command(work: suspend () -> T): Promise<T> =
    try { core.submit(work).asNitroPromise() }
    catch (error: Throwable) { Promise<T>().also { it.reject(error) } }

  override val pageCount: Double get() = core.withDocument { core.state.pageCount.toDouble() }
  override fun getState(): DocumentState = core.documentInfo()
  override fun getPage(index: PageQuery): Promise<HybridDocumentPageSpec> = command {
    HybridDocumentPage(core, index.match({ core.getPage(it) }, { core.getPage(it) }))
  }
  override fun getPageIdsByTag(tag: String): Array<String> = core.getPageIdsByTag(tag)
  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = command { core.fonts.load(fonts) }
  override fun addPages(options: DocumentAddPagesOptions): Promise<DocumentAddPagesResult> = command {
    val dimensions = options.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: (if (core.state.hasDocument) core.state.pageMetadata(0).dimensions else null) ?: PdfPageDimensions(595.28, 841.89)
    val added = core.addPages(AddPagesOptions(tag = options.tag, type = null, sources = options.sources,
      imagePageSize = options.imagePageSize, targetDpi = options.targetDpi, jpegQuality = options.jpegQuality,
      activePage = null), dimensions)
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
internal class HybridDocumentPage(core: DocumentCore, context: PreparedPageContext) : HybridDocumentPageSpec() {
  private val core = WeakReference(core)
  private val prepared = WeakReference(context)
  private val context: PreparedPageContext get() = prepared.get()
    ?: throw PdfSessionException("operation_cancelled", "The prepared page was released")
  private fun <T> use(action: (DocumentCore) -> T): T = core.get()?.let(action)
    ?: throw PdfSessionException("operation_cancelled", "The document has been released")
  override fun getState(): PageInfo = use { it.pageInfo(context) }
  override fun resolveInputUnderline(options: ResolveInputUnderlineOptions) = use { it.text.resolve(context, options.resolutionOptions()) }
  override fun createInputArea(options: CreateInputAreaOptions) = use { it.text.resolve(context, options.resolutionOptions()) }
  override fun getTextValue(id: Double) = use { it.text.getValue(context, id) }
  override fun setTextValue(id: Double, text: String, options: TextAnnotationOptions?) = use { it.text.setValue(context, id, text, options) }
  override fun setTextOptions(id: Double, options: TextAnnotationOptions) = use { it.text.setOptions(context, id, options) }
  override fun adjustTextSize(id: Double, delta: Double) = use { it.text.adjustSize(context, id, delta) }
  override fun getInputTarget(id: Double) = use { it.text.getEntry(context, id) }
  override fun getInputTargets() = use { it.text.getEntries(context) }
}
