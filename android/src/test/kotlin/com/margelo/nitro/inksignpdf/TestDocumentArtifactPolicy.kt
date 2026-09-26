package com.margelo.nitro.inksignpdf

import java.io.File
import java.nio.file.Files
import java.util.UUID

internal class TestDocumentArtifactPolicy : DocumentArtifactPolicy {
  private val root = Files.createTempDirectory("inksign-document-test").toFile()
  val allocatedWorkingFiles = mutableListOf<File>()

  override fun allocateSignedOutput(): File = allocate("signed-", ".pdf")
  override fun allocateDebugRecording(): File = allocate("debug-", ".csv")
  override fun allocateExportScratch(): File = allocate("export-", ".tmp")
  override fun allocateStagedInput(): File = allocate("input-", ".tmp")
  override fun allocateWorkingPdf(): File = allocate("working-", ".pdf").also(allocatedWorkingFiles::add)
  override fun allocateMutationScratch(): File = allocate("mutation-", ".tmp")
  override fun validatedSignedOutput(path: String, source: File): File = File(path)
  override fun deleteExact(file: File) { file.delete() }

  private fun allocate(prefix: String, suffix: String): File =
    File(root, "$prefix${UUID.randomUUID()}$suffix").also { it.createNewFile() }
}
