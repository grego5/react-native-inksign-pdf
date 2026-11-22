import { useState, type RefObject } from 'react';
import * as Sharing from 'expo-sharing';
import { Alert, Pressable, StyleSheet, Text, View } from 'react-native';
import { type InkSignViewHandle } from '@grego5/react-native-inksign-pdf';
import { filePathToUri } from './localFiles';

type DebugRecorderProps = {
  inkSignViewRef: RefObject<InkSignViewHandle | null>;
};

export function DebugRecorder({ inkSignViewRef }: DebugRecorderProps) {
  const [recording, setRecording] = useState(false);

  function startRecording() {
    try {
      const view = inkSignViewRef.current;
      if (view === null) throw new Error('The InkSignView is not available');
      view.startDebugRecording();
      setRecording(true);
    } catch (error) {
      Alert.alert('Recording start failed', String(error));
    }
  }

  function stopRecording() {
    try {
      const view = inkSignViewRef.current;
      if (view === null) throw new Error('The InkSignView is not available');
      view.stopDebugRecording();
      setRecording(false);
    } catch (error) {
      Alert.alert('Recording stop failed', String(error));
    }
  }

  async function exportRecording() {
    try {
      const privatePath = await inkSignViewRef.current?.exportDebugRecording();
      if (privatePath === undefined) throw new Error('The InkSignView is not available');
      if (!(await Sharing.isAvailableAsync())) {
        throw new Error('System file sharing is unavailable');
      }
      await Sharing.shareAsync(filePathToUri(privatePath), {
        mimeType: 'text/csv',
        dialogTitle: 'Export ink trace',
      });
    } catch (error) {
      Alert.alert('Recording export failed', String(error));
    }
  }

  return (
    <View style={styles.recordingCard}>
      <View style={styles.row}>
        <RecorderAction label="Start" disabled={recording} onPress={startRecording} />
        <RecorderAction label="Stop" disabled={!recording} onPress={stopRecording} />
        <RecorderAction
          label="Export CSV"
          disabled={recording}
          onPress={() => void exportRecording()}
        />
      </View>
    </View>
  );
}

function RecorderAction({
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
  recordingCard: { gap: 8, padding: 12, borderRadius: 8, backgroundColor: '#fff7df' },
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
});
