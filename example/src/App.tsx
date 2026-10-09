import { useRef, useState } from 'react';
import * as Sharing from 'expo-sharing';
import {
  Alert, KeyboardAvoidingView, Modal, Platform, Pressable, StyleSheet, Text, TextInput, View,
} from 'react-native';
import { SafeAreaView, SafeAreaProvider } from 'react-native-safe-area-context';
import {
  InkSignView,
  isOperationCancelled,
  type AddPagesOptions,
  type PageInfo,
  type ViewerState,
  type ViewportOptions,
  type InkSignViewHandle,
} from '@grego5/react-native-inksign-pdf';
import { androidFallbackFont, ensureFallbackFont } from './fallbackFont';
import { DebugRecorder } from './DebugRecorder';

export default function App() {
  const debugRecorderEnabled =
    Platform.OS === 'android' && process.env.EXPO_PUBLIC_ENABLE_DEBUG_RECORDER === 'true';
  const inkSignViewRef = useRef<InkSignViewHandle>(null);
  const modeRef = useRef<ViewerState['mode']>('view');
  const [pageInfo, setPageInfo] = useState<PageInfo | null>(null);
  const [textSelected, setTextSelected] = useState(false);
  const [signingFieldName, setSigningFieldName] = useState<string | null>(null);

  const [state, setState] = useState<ViewerState>({
    documentId: null,
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
    error: null,
  });

  function handleStateChange(nextState: ViewerState) {
    modeRef.current = nextState.mode;
    setState(nextState);
  }

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
      const session = target === 'edit' ? inkSignView.setMode('ink') : inkSignView.setMode('view');
      if (viewport !== undefined) await session.setViewport(viewport);
    } catch (error) {
      if (!isOperationCancelled(error)) Alert.alert('Mode change failed', String(error));
    }
  }

  function toggleMode() {
    void transitionMode(state.mode === 'ink' ? 'view' : 'edit');
  }

  async function focusSigningField() {
    const fieldName = signingFieldName?.trim();
    const view = inkSignViewRef.current;
    if (!fieldName || !view) return;
    setSigningFieldName(null);
    try {
      const session = view.setMode('view');
      const page = await session.getPage();
      const id = page.resolveText({ fieldName, direction: 'auto' });
      await page.focusText(id, { zoom: 3, verticalAnchor: 'bottom', edgeOffset: 8 });
      view.setMode('ink');
    } catch (error) {
      if (!isOperationCancelled(error)) Alert.alert('Field focus failed', String(error));
    }
  }

  function fitPage() {
    void transitionMode('view', {});
  }

  async function toggleTextPlacement() {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null || pageInfo === null) return;
    const placementArmed = modeRef.current === 'textAdd';

    try {
      if (placementArmed) {
        inkSignView.setMode('view');
      } else {
        inkSignView.setMode('text');
      }
    } catch (error) {
      Alert.alert(
        placementArmed ? 'Cancel text placement failed' : 'Place text failed',
        String(error),
      );
    }
  }

  function updateSelectedText(delta: number | null) {
    const inkSignView = inkSignViewRef.current;
    if (inkSignView === null) return;
    try {
      const text = inkSignView.getSelectedText();
      if (delta === null) text?.setValue('');
      else text?.adjustSize(delta);
    } catch (error) {
      Alert.alert('Update text failed', String(error));
    }
  }

  function clearCurrentContent() {
    const view = inkSignViewRef.current;
    if (!view) return;
    if (state.mode === 'textEdit') {
      updateSelectedText(null);
      return;
    }
    try {
      if (state.mode === 'ink') view.clearInk();
      else if (state.mode === 'textAdd') view.setMode('view');
    } catch (error) {
      Alert.alert('Clear failed', String(error));
    }
  }

  function handlePageChange(next: PageInfo) {
    setPageInfo(next);
    setTextSelected(false);
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
      await Sharing.shareAsync(signedPath, {
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
            androidFallbackFont={Platform.OS === 'android' ? androidFallbackFont : undefined}
            strokeColor="#111111"
            strokeMinWidth={2.0}
            strokeMaxWidth={4.0}
            strokeSmoothing={0.4}
            defaultTextFontSize={16}
            onStateChange={handleStateChange}
            onPageChange={handlePageChange}
            onTextSelectionChange={selection => setTextSelected(selection !== null)}
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
            <Action
              label={state.mode === 'ink' ? 'View' : 'Sign'}
              onPress={toggleMode}
              onLongPress={state.mode === 'ink' || pageInfo === null
                ? undefined : () => setSigningFieldName('')}
            />
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
            {['ink', 'textEdit', 'textAdd'].includes(state.mode) && (
              <Action
                label={state.mode === 'textAdd' ? 'Cancel text' : 'Clear'}
                disabled={state.mode === 'textEdit' && !textSelected}
                onPress={() => void clearCurrentContent()}
              />
            )}
          </View>

          <View style={styles.row}>
            <Action
              label="Text +"
              disabled={pageInfo === null}
              active={state.mode === 'textAdd'}
              onPress={() => void toggleTextPlacement()}
            />
            <Action
              label="Size +"
              disabled={
                pageInfo === null || !textSelected
              }
              onPress={() => void updateSelectedText(1)}
            />
            <Action
              label="Size −"
              disabled={
                pageInfo === null || !textSelected
              }
              onPress={() => void updateSelectedText(-1)}
            />
          </View>

          {/* {__DEV__ ? <DebugRecorder inkSignViewRef={inkSignViewRef} /> : null} */}
        </View>
        <Modal
          visible={signingFieldName !== null}
          transparent
          animationType="fade"
          onRequestClose={() => setSigningFieldName(null)}>
          <KeyboardAvoidingView
            style={styles.dialogBackdrop}
            behavior={Platform.OS === 'ios' ? 'padding' : 'height'}>
            <View style={styles.dialog}>
              <Text style={styles.dialogTitle}>Focus signing field</Text>
              <TextInput
                autoFocus
                accessibilityLabel="Field name"
                placeholder="Field name"
                value={signingFieldName ?? ''}
                onChangeText={setSigningFieldName}
                autoCorrect={false}
                returnKeyType="go"
                onSubmitEditing={() => void focusSigningField()}
                style={styles.dialogInput}
              />
              <View style={styles.row}>
                <Action label="Cancel" onPress={() => setSigningFieldName(null)} />
                <Action
                  label="Focus and sign"
                  disabled={!signingFieldName?.trim()}
                  onPress={() => void focusSigningField()}
                />
              </View>
            </View>
          </KeyboardAvoidingView>
        </Modal>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

function Action({
  label,
  accessibilityLabel,
  onPress,
  onLongPress,
  disabled = false,
  active = false,
}: {
  label: string;
  accessibilityLabel?: string;
  onPress: () => void;
  onLongPress?: () => void;
  disabled?: boolean;
  active?: boolean;
}) {
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      onLongPress={onLongPress}
      style={[
        styles.button,
        active && styles.buttonActive,
        disabled && styles.buttonDisabled,
      ]}>
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  dialogBackdrop: {
    flex: 1, justifyContent: 'center', padding: 24, backgroundColor: '#0008',
  },
  dialog: { padding: 20, gap: 16, borderRadius: 12, backgroundColor: '#fff' },
  dialogTitle: { fontSize: 18, fontWeight: '600', color: '#111' },
  dialogInput: {
    borderWidth: 1, borderColor: '#aaa', borderRadius: 6, padding: 12, color: '#111',
  },
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
  buttonActive: { backgroundColor: '#17386b' },
  buttonText: { color: '#fff', fontWeight: '600' },
  pageIndicator: { alignSelf: 'center', color: '#333', paddingVertical: 10 },
  surfaceFrame: { flex: 1, overflow: 'hidden', borderRadius: 8, backgroundColor: '#ddd' },
  surface: { flex: 1 },
  state: { fontFamily: 'monospace', color: '#333' },
  hint: { fontSize: 12, color: '#666' },
  error: { fontSize: 12, color: '#b00020' },
});
