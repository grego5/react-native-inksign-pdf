package com.margelo.nitro.inksignpdf.example

import com.facebook.react.ReactActivity
import com.facebook.react.defaults.DefaultReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled

class MainActivity : ReactActivity() {
  override fun getMainComponentName(): String = "ReactNativeInkSignPdfExample"

  override fun createReactActivityDelegate() =
    DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)
}
