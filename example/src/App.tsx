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
import { SafeAreaView, SafeAreaProvider } from 'react-native-safe-area-context';
import {
  InkSignView,
  type PageInfo,
  type StateChangeEvent,
  type ViewportOptions,
  type InkSignViewHandle,
} from '@grego5/react-native-inksign-pdf';
import { ensureFallbackFont, fallbackFontPath } from './fallbackFont';
import { cleanupLocalFile, filePathToUri, fileUriToPath } from './localFiles';
import { DebugRecorder } from './DebugRecorder';

type SelectedPdf = {
  name: string;
  path: string;
};

export default function App() {
  const inkSignViewRef = useRef<InkSignViewHandle>(null);
  const selectedPdf = useRef<SelectedPdf | null>(null);
  const [pageInfo, setPageInfo] = useState<PageInfo | null>(null);
  const [state, setState] = useState<StateChangeEvent>({
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
  });

  useEffect(() => {
    void ensureFallbackFont().catch((error) => {
      console.warn('Unable to install example PDFium fallback font', error);
    });
    return () => {
      cleanupLocalFile(selectedPdf.current?.path, 'picker PDF copy');
    };
  }, []);

  async function choosePdf() {
    try {
      const inkSignView = inkSignViewRef.current;
      if (inkSignView === null) {
        throw new Error('The InkSignView view is not available');
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
        await ensureFallbackFont();
        const opened = await inkSignView.open(pickerPath);
        setPageInfo(opened);
        selectedPdf.current = { name, path: pickerPath };
        if (previousPath !== undefined && previousPath !== pickerPath) {
          cleanupLocalFile(previousPath, 'picker PDF copy');
        }
      } catch (error) {
        if (pickerPath !== previousPath) cleanupLocalFile(pickerPath, 'picker PDF copy');
        throw error;
      }
    } catch (error) {
      if (isErrorWithCode(error) && error.code === errorCodes.OPERATION_CANCELED) {
        return;
      }

      Alert.alert('PDF open failed', String(error));
    }
  }

  function transitionMode(target: 'view' | 'edit', viewport?: ViewportOptions) {
    const view = inkSignViewRef.current;
    if (view === null) {
      Alert.alert('Mode change failed', 'The InkSignView is not available');
      return;
    }
    try {
      if (target === 'edit') {
        view.enterEditMode(viewport);
      } else {
        view.enterViewMode(viewport);
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

  function toggleTextPlacement() {
    const view = inkSignViewRef.current;
    if (view === null || pageInfo === null) return;
    const placementArmed = state.mode === 'textPlacement';

    try {
      if (placementArmed) {
        view.insertAnnotationOff();
      } else {
        view.insertAnnotationOn();
      }
    } catch (error) {
      Alert.alert(
        placementArmed ? 'Cancel text placement failed' : 'Place text failed',
        String(error),
      );
    }
  }

  function runTextCommand(command: () => unknown, name: string) {
    const view = inkSignViewRef.current;
    if (view === null || pageInfo === null) return;

    try {
      command();
    } catch (error) {
      Alert.alert(`${name} failed`, String(error));
    }
  }

  function navigatePage(direction: 'next' | 'previous') {
    const view = inkSignViewRef.current;
    if (view === null) return;
    try {
      if (direction === 'next') {
        view.nextPage();
      } else {
        view.previousPage();
      }
    } catch (error) {
      Alert.alert('Page change failed', String(error));
    }
  }

  async function finalizePdf() {
    const selected = selectedPdf.current;
    if (selected === null) return;

    try {
      const signedPath = await inkSignViewRef.current?.finalize();
      if (signedPath === undefined) {
        throw new Error('The InkSignView is not available');
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

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.surfaceFrame}>
          <InkSignView
            ref={inkSignViewRef}
            style={styles.surface}
            fallbackFont={{ path: fallbackFontPath }}
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
          <View style={styles.row}>
            <Action label="Open" onPress={choosePdf} />
            <Action
              label="Next"
              disabled={pageInfo === null || pageInfo.pageIndex >= pageInfo.pageCount - 1}
              onPress={() => void navigatePage('next')}
            />
            <Text style={styles.pageIndicator}>
              {pageInfo === null
                ? 'Page: N/A'
                : `Page: ${pageInfo.pageIndex + 1}/${pageInfo.pageCount}`}
            </Text>
            <Action
              label="Prev"
              disabled={pageInfo === null || pageInfo.pageIndex === 0}
              onPress={() => void navigatePage('previous')}
            />
            <Action
              label="Export"
              disabled={!state.isDirty || selectedPdf.current === null}
              onPress={finalizePdf}
            />
          </View>

          <View style={styles.row}>
            <Action label={state.mode === 'draw' ? 'View' : 'Sign'} onPress={toggleMode} />
            <Action label="Fit" onPress={fitPage} />
            <Action
              label="Undo"
              disabled={!state.canUndo}
              onPress={() => inkSignViewRef.current?.undo()}
            />
            <Action
              label="Redo"
              disabled={!state.canRedo}
              onPress={() => inkSignViewRef.current?.redo()}
            />
            <Action
              label="Clear"
              disabled={!state.canUndo}
              onPress={() => inkSignViewRef.current?.clear()}
            />
          </View>

          <View style={styles.row}>
            <Action
              label="Text +"
              disabled={pageInfo === null}
              onPress={() => void toggleTextPlacement()}
            />
            <Action
              label="Text −"
              disabled={
                pageInfo === null || (state.mode !== 'textEditing' && state.mode !== 'textSelected')
              }
              onPress={() =>
                void runTextCommand(
                  () => inkSignViewRef.current!.removeTextAnnotation(),
                  'Remove text',
                )
              }
            />
            <Action
              label="Size +"
              disabled={
                pageInfo === null || (state.mode !== 'textEditing' && state.mode !== 'textSelected')
              }
              onPress={() =>
                void runTextCommand(
                  () => inkSignViewRef.current!.increaseTextSize(),
                  'Increase text size',
                )
              }
            />
            <Action
              label="Size −"
              disabled={
                pageInfo === null || (state.mode !== 'textEditing' && state.mode !== 'textSelected')
              }
              onPress={() =>
                void runTextCommand(
                  () => inkSignViewRef.current!.decreaseTextSize(),
                  'Decrease text size',
                )
              }
            />
          </View>

          {/* {__DEV__ ? <DebugRecorder inkSignViewRef={inkSignViewRef} /> : null} */}
        </View>
      </SafeAreaView>
    </SafeAreaProvider>
  );
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
  fileLabel: { fontSize: 12, color: '#666', textTransform: 'uppercase' },
  fileName: { color: '#111', fontWeight: '600' },
  outputPath: { fontSize: 12, color: '#555' },
  row: { flexDirection: 'row', gap: 8 },
  button: {
    flex: 1,
    flexBasis: 0,
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

