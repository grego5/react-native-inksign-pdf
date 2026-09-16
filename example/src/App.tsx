import React, { useEffect, useRef, useState } from 'react';
import {
  errorCodes,
  isErrorWithCode,
  keepLocalCopy,
  pick,
  saveDocuments,
  types,
} from '@react-native-documents/picker';
import { viewDocument } from '@react-native-documents/viewer';
import { Alert, Pressable, StyleSheet, Text, View } from 'react-native';
import RNFS from 'react-native-fs';
import { SafeAreaView, SafeAreaProvider } from 'react-native-safe-area-context';
import {
  PdfView,
  type PageInfo,
  type StateChangeEvent,
  type ViewportOptions,
  type PdfViewHandle,
} from '@grego5/react-native-inksign-pdf';

type SelectedPdf = {
  name: string;
  path: string;
};

export default function App() {
  const viewRef = useRef<PdfViewHandle>(null);
  const selectedPdf = useRef<SelectedPdf | null>(null);
  const [recording, setRecording] = useState(false);
  const [pageInfo, setPageInfo] = useState<PageInfo | null>(null);
  const [state, setState] = useState<StateChangeEvent>({
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
  });

  function cleanupPickerPath(path: string | undefined) {
    if (path === undefined) return;
    void RNFS.unlink(path)
      .catch(error => {
        console.warn('Unable to retire picker PDF copy', path, error);
      });
  }

  useEffect(() => {
    return () => {
      cleanupPickerPath(selectedPdf.current?.path);
    };
  }, []);

  async function choosePdf() {
    try {
      const view = viewRef.current;
      if (view === null) {
        throw new Error('The PDF view is not available');
      }

      const [pickedFile] = await pick({ type: [types.pdf] });
      const [copy] = await keepLocalCopy({
        files: [
          {
            uri: pickedFile.uri,
            fileName: pickedFile.name ?? 'source.pdf',
          },
        ],
        destination: 'cachesDirectory',
      });

      if (copy.status !== 'success') {
        throw new Error(copy.copyError);
      }

      const name = pickedFile.name ?? 'source.pdf';
      const pickerPath = fileUriToPath(copy.localUri);
      const previousPath = selectedPdf.current?.path;

      try {
        const opened = await view.open(pickerPath);
        setPageInfo(opened);
        selectedPdf.current = { name, path: pickerPath };
        if (previousPath !== undefined && previousPath !== pickerPath) {
          cleanupPickerPath(previousPath);
        }
      } catch (error) {
        if (pickerPath !== previousPath) cleanupPickerPath(pickerPath);
        throw error;
      }
    } catch (error) {
      if (isErrorWithCode(error) && error.code === errorCodes.OPERATION_CANCELED) {
        return;
      }

      Alert.alert('PDF open failed', String(error));
    }
  }

  async function transitionMode(target: 'view' | 'edit', viewport?: ViewportOptions) {
    const view = viewRef.current;
    if (view === null) {
      Alert.alert('Mode change failed', 'The PDF view is not available');
      return;
    }
    try {
      if (target === 'edit') {
        await view.enterEditMode(viewport);
      } else {
        await view.enterViewMode(viewport);
      }
    } catch (error) {
      Alert.alert('Mode change failed', String(error));
    }
  }

  function toggleMode() {
    void transitionMode(state.mode === 'draw' ? 'view' : 'edit');
  }

  function fitPage() {
    void transitionMode('view', {});
  }

  async function toggleTextPlacement() {
    const view = viewRef.current;
    if (view === null || pageInfo === null) return;
    const placementArmed = state.mode === 'textPlacement';

    try {
      if (placementArmed) {
        await view.insertAnnotationOff();
      } else {
        await view.insertAnnotationOn();
      }
    } catch (error) {
      Alert.alert(
        placementArmed ? 'Cancel text placement failed' : 'Place text failed',
        String(error),
      );
    }
  }

  async function runTextCommand(
    command: () => Promise<unknown>,
    name: string,
  ) {
    const view = viewRef.current;
    if (view === null || pageInfo === null) return;

    try {
      await command();
    } catch (error) {
      Alert.alert(`${name} failed`, String(error));
    }
  }

  async function navigatePage(direction: 'next' | 'previous') {
    const view = viewRef.current;
    if (view === null) return;
    try {
      const next = direction === 'next' ? await view.nextPage() : await view.previousPage();
      setPageInfo(next);
    } catch (error) {
      Alert.alert('Page change failed', String(error));
    }
  }

  async function finalizePdf() {
    const selected = selectedPdf.current;
    if (selected === null) return;

    try {
      const signedPath = await viewRef.current?.finalize();
      if (signedPath === undefined) {
        throw new Error('The PDF view is not available');
      }
      const [saved] = await saveDocuments({
          sourceUris: [filePathToUri(signedPath)],
          mimeType: 'application/pdf',
          fileName: `signed-${selected.name}`,
          copy: true,
        });
      if (saved.error !== null) throw new Error(saved.error);
      await viewDocument({
          uri: saved.uri,
          mimeType: 'application/pdf',
        });
    } catch (error) {
      Alert.alert('Export failed', String(error));
    }
  }

  function startRecording() {
    try {
      viewRef.current?.startDebugRecording();
      setRecording(true);
    } catch (error) {
      Alert.alert('Recording start failed', String(error));
    }
  }

  function stopRecording() {
    try {
      viewRef.current?.stopDebugRecording();
      setRecording(false);
    } catch (error) {
      Alert.alert('Recording stop failed', String(error));
    }
  }

  async function exportRecording() {
    try {
      const privatePath = await viewRef.current?.exportDebugRecording();
      if (privatePath === undefined) throw new Error('The PDF view is not available');
      const fileName = privatePath.slice(privatePath.lastIndexOf('/') + 1);
      const [saved] = await saveDocuments({
        sourceUris: [filePathToUri(privatePath)],
        mimeType: 'text/csv',
        fileName,
      });
      if (saved.error !== null) throw new Error(saved.error);
    } catch (error) {
      if (isErrorWithCode(error) && error.code === errorCodes.OPERATION_CANCELED) return;
      Alert.alert('Recording export failed', String(error));
    }
  }

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.surfaceFrame}>
          <PdfView
            ref={viewRef}
            style={styles.surface}
            strokeColor="#111111"
            strokeMinWidth={2.0}
            strokeMaxWidth={4.0}
            strokeSmoothing={0.4}
            defaultTextFontSize={16}
            onStateChange={setState}
            onPageChange={setPageInfo}
          />
        </View>

        <View style={styles.toolbar}>
          <Action label="Choose PDF" onPress={choosePdf} />

          <View style={styles.row}>
            <Action label={state.mode === 'draw' ? 'View' : 'Sign'} onPress={toggleMode} />
            <Action label="Fit" onPress={fitPage} />
            <Action
              label="Previous"
              disabled={pageInfo === null || pageInfo.pageIndex === 0}
              onPress={() => void navigatePage('previous')}
            />
            <Action
              label="Next"
              disabled={pageInfo === null || pageInfo.pageIndex >= pageInfo.pageCount - 1}
              onPress={() => void navigatePage('next')}
            />
            <Action
              label="Undo"
              disabled={!state.canUndo}
              onPress={() => viewRef.current?.undo()}
            />
            <Action
              label="Redo"
              disabled={!state.canRedo}
              onPress={() => viewRef.current?.redo()}
            />
            <Action
              label="Clear"
              disabled={!state.canUndo}
              onPress={() => viewRef.current?.clear()}
            />
            <Action
              label={state.mode === 'textPlacement' ? 'Cancel text' : 'Place text'}
              disabled={pageInfo === null}
              onPress={() => void toggleTextPlacement()}
            />
            <Action
              label="Text +"
              disabled={pageInfo === null ||
                (state.mode !== 'textEditing' && state.mode !== 'textSelected')}
              onPress={() =>
                void runTextCommand(
                  () => viewRef.current!.increaseTextSize(),
                  'Increase text size',
                )
              }
            />
            <Action
              label="Text −"
              disabled={pageInfo === null ||
                (state.mode !== 'textEditing' && state.mode !== 'textSelected')}
              onPress={() =>
                void runTextCommand(
                  () => viewRef.current!.decreaseTextSize(),
                  'Decrease text size',
                )
              }
            />
            <Action
              label="Remove text"
              disabled={pageInfo === null ||
                (state.mode !== 'textEditing' && state.mode !== 'textSelected')}
              onPress={() =>
                void runTextCommand(
                  () => viewRef.current!.removeTextAnnotation(),
                  'Remove text',
                )
              }
            />
            <Action
              label="Export"
              disabled={!state.isDirty || selectedPdf.current === null}
              onPress={finalizePdf}
            />
            <Text style={styles.pageIndicator}>
              {pageInfo === null
                ? 'No PDF'
                : `Page ${pageInfo.pageIndex + 1} of ${pageInfo.pageCount}`}
            </Text>
            {__DEV__ ? (
              <View style={styles.recordingCard}>
                <View style={styles.row}>
                  <Action label="Start" disabled={recording} onPress={startRecording} />
                  <Action label="Stop" disabled={!recording} onPress={stopRecording} />
                  <Action label="Export CSV" disabled={recording} onPress={exportRecording} />
                </View>
              </View>
            ) : null}
          </View>
        </View>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

function fileUriToPath(uri: string): string {
  return uri.startsWith('file://') ? decodeURIComponent(uri.slice('file://'.length)) : uri;
}

function filePathToUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}

function Action({
  label,
  onPress,
  disabled = false,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={[styles.button, disabled && styles.buttonDisabled]}>
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#f5f5f5' },
  toolbar: { padding: 8, gap: 8 },
  title: { fontSize: 24, fontWeight: '700', color: '#111' },
  subtitle: { color: '#555' },
  fileCard: { gap: 8, padding: 12, borderRadius: 8, backgroundColor: '#fff' },
  recordingCard: { gap: 8, padding: 12, borderRadius: 8, backgroundColor: '#fff7df' },
  fileLabel: { fontSize: 12, color: '#666', textTransform: 'uppercase' },
  fileName: { color: '#111', fontWeight: '600' },
  outputPath: { fontSize: 12, color: '#555' },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  button: {
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 6,
    backgroundColor: '#2457a6',
  },
  buttonDisabled: { backgroundColor: '#aeb7c7' },
  buttonText: { color: '#fff', fontWeight: '600' },
  pageIndicator: { alignSelf: 'center', color: '#333', paddingVertical: 10 },
  surfaceFrame: { flex: 1, overflow: 'hidden', borderRadius: 8, backgroundColor: '#ddd' },
  surface: { flex: 1 },
  state: { fontFamily: 'monospace', color: '#333' },
  hint: { fontSize: 12, color: '#666' },
  error: { fontSize: 12, color: '#b00020' },
});
