import { useRef, useState } from 'react';
import * as Sharing from 'expo-sharing';
import { Alert, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView, SafeAreaProvider } from 'react-native-safe-area-context';
import {
  InkSignView,
  type AddPagesOptions,
  type PageInfo,
  type StateChangeEvent,
  type ViewportOptions,
  type InkSignViewHandle,
} from '@grego5/react-native-inksign-pdf';
import { ensureFallbackFont, fallbackFontPath } from './fallbackFont';
import { DebugRecorder } from './DebugRecorder';
import { filePathToUri } from './localFiles';

export default function App() {
  const debugRecorderEnabled =
    Platform.OS === 'android' && process.env.EXPO_PUBLIC_ENABLE_DEBUG_RECORDER === 'true';
  const inkSignViewRef = useRef<InkSignViewHandle>(null);
  const [pageInfo, setPageInfo] = useState<PageInfo | null>(null);

  const [state, setState] = useState<StateChangeEvent>({
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
  });

  async function addPages(options?: AddPagesOptions) {
    try {
      const inkSignView = inkSignViewRef.current;
      if (inkSignView === null) {
        throw new Error('The InkSignView is not available');
      }

      if (Platform.OS === 'android') await ensureFallbackFont();
      const result = await inkSignView.addPages(options);
      if (result.pageInfo !== undefined) setPageInfo(result.pageInfo);
    } catch (error) {
      Alert.alert('Add pages failed', String(error));
    }
  }

  async function transitionMode(target: 'view' | 'edit', viewport?: ViewportOptions) {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null) {
      Alert.alert('Mode change failed', 'The InkSignView is not available');
      return;
    }
    try {
      if (target === 'edit') {
        inkSignView.enterEditMode(viewport);
      } else {
        inkSignView.enterViewMode(viewport);
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
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null || pageInfo === null) return;
    const placementArmed = state.mode === 'textPlacement';

    try {
      if (placementArmed) {
        inkSignView.insertAnnotationOff();
      } else {
        inkSignView.insertAnnotationOn();
      }
    } catch (error) {
      Alert.alert(
        placementArmed ? 'Cancel text placement failed' : 'Place text failed',
        String(error),
      );
    }
  }

  async function runTextCommand(command: () => unknown | Promise<unknown>, name: string) {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null || pageInfo === null) return;

    try {
      await command();
    } catch (error) {
      Alert.alert(`${name} failed`, String(error));
    }
  }

  function navigatePage(direction: 'next' | 'previous') {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null) return;
    try {
      if (direction === 'next') {
        inkSignView.nextPage();
      } else {
        inkSignView.previousPage();
      }
    } catch (error) {
      Alert.alert('Page change failed', String(error));
    }
  }

  async function removeActivePage() {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null || pageInfo === null) return;
    try {
      setPageInfo(await inkSignView.removePage());
    } catch (error) {
      Alert.alert('Remove page failed', String(error));
    }
  }

  async function moveActivePageBy(delta: -1 | 1) {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null || pageInfo === null) return;
    try {
      setPageInfo(await inkSignView.movePage(pageInfo.pageIndex + delta));
    } catch (error) {
      Alert.alert('Move page failed', String(error));
    }
  }

  async function finalizePdf() {
    try {
      const signedPath = await inkSignViewRef.current?.finalize();
      if (signedPath === undefined) {
        throw new Error('The InkSignView is not available');
      }
      if (!(await Sharing.isAvailableAsync())) {
        throw new Error('System PDF sharing is unavailable');
      }
      await Sharing.shareAsync(filePathToUri(signedPath), {
        mimeType: 'application/pdf',
        dialogTitle: 'Signed document',
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
            fallbackFont={Platform.OS === 'android' ? { path: fallbackFontPath } : undefined}
            strokeColor="#111111"
            strokeMinWidth={2.0}
            strokeMaxWidth={4.0}
            strokeSmoothing={0.4}
            defaultTextFontSize={16}
            onStateChange={setState}
            onPageChange={setPageInfo}
          />
        </View>

        {debugRecorderEnabled && <DebugRecorder inkSignViewRef={inkSignViewRef} />}

        <View style={styles.toolbar}>
          <View style={styles.row}>
            {pageInfo === null ? (
              <Action label="Open file" onPress={() => void addPages()} />
            ) : (
              <Action label="Export file" disabled={!state.isDirty} onPress={finalizePdf} />
            )}
            <Action
              label="Add pages"
              disabled={pageInfo === null}
              onPress={() => void addPages()}
            />
            <Action
              label="Remove page"
              disabled={pageInfo === null || pageInfo.pageCount <= 1}
              onPress={() => void removeActivePage()}
            />
          </View>

          <View style={styles.row}>
            <Action
              label="<"
              accessibilityLabel="Previous page"
              disabled={pageInfo === null || pageInfo.pageIndex === 0}
              onPress={() => void navigatePage('previous')}
            />
            <Text style={styles.pageIndicator}>
              {pageInfo === null
                ? 'Page: N/A'
                : `Page: ${pageInfo.pageIndex + 1}/${pageInfo.pageCount}`}
            </Text>
            <Action
              label=">"
              accessibilityLabel="Next Page"
              disabled={pageInfo === null || pageInfo.pageIndex >= pageInfo.pageCount - 1}
              onPress={() => void navigatePage('next')}
            />
            <Action
              label="<"
              accessibilityLabel="Move page backward"
              disabled={pageInfo === null || pageInfo.pageIndex === 0}
              onPress={() => void moveActivePageBy(-1)}
            />
            <Text style={styles.pageIndicator}>Move</Text>
            <Action
              label=">"
              accessibilityLabel="Move page forward"
              disabled={pageInfo === null || pageInfo.pageIndex >= pageInfo.pageCount - 1}
              onPress={() => void moveActivePageBy(1)}
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
  accessibilityLabel,
  onPress,
  disabled = false,
}: {
  label: string;
  accessibilityLabel?: string;
  onPress: () => void;
  disabled?: boolean;
}) {
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
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

