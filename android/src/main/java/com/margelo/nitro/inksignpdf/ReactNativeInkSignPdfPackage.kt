package com.margelo.nitro.inksignpdf

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.uimanager.ViewManager
import com.margelo.nitro.inksignpdf.views.HybridInkSignViewManager

class ReactNativeInkSignPdfPackage : BaseReactPackage() {
  companion object {
    init {
      ReactNativeInkSignPdfOnLoad.initializeNative()
    }
  }

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? = null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider =
    ReactModuleInfoProvider { emptyMap() }

  override fun createViewManagers(
    reactContext: ReactApplicationContext,
  ): List<ViewManager<*, *>> {
    CacheArtifactPolicy.initialize(reactContext.applicationContext)
    return listOf(HybridInkSignViewManager())
  }
}
