import 'package:flutter/material.dart';
import '../services/local_model_service.dart';

class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key, required this.localModel});

  final LocalModelService localModel;

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  final _testPromptController = TextEditingController(text: 'What is 2 + 2?');
  String? _testOutput;
  bool _isTesting = false;
  String? _testError;

  @override
  void dispose() {
    _testPromptController.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    final prompt = _testPromptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _isTesting = true;
      _testOutput = null;
      _testError = null;
    });

    try {
      final response = await widget.localModel.runTestInference(prompt: prompt);
      if (mounted) {
        setState(() {
          _testOutput = response;
          _isTesting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testError = e.toString();
          _isTesting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: widget.localModel,
      builder: (context, _) {
        final lm = widget.localModel;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Local LLM Manager'),
            actions: [
              if (lm.hasSelectedModel)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Clear Model Reference',
                  onPressed: () => _confirmClearModel(context),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildStatusCard(lm, colorScheme),
              const SizedBox(height: 16),
              _buildActionsSection(lm, colorScheme),
              const SizedBox(height: 16),
              _buildInferenceTestSection(lm, colorScheme),
              const SizedBox(height: 16),
              _buildConfigurationSection(lm, colorScheme),
              const SizedBox(height: 16),
              _buildTechnicalDetailsSection(lm, colorScheme),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusCard(LocalModelService lm, ColorScheme colorScheme) {
    final Color badgeColor;
    final IconData badgeIcon;

    switch (lm.state) {
      case LocalModelState.ready:
        badgeColor = Colors.green;
        badgeIcon = Icons.check_circle;
        break;
      case LocalModelState.loading:
      case LocalModelState.validating:
        badgeColor = Colors.blue;
        badgeIcon = Icons.hourglass_top;
        break;
      case LocalModelState.generating:
        badgeColor = Colors.purple;
        badgeIcon = Icons.auto_awesome;
        break;
      case LocalModelState.selected:
        badgeColor = Colors.orange;
        badgeIcon = Icons.file_present;
        break;
      case LocalModelState.noModelSelected:
        badgeColor = Colors.grey;
        badgeIcon = Icons.warning_amber;
        break;
      default:
        badgeColor = Colors.red;
        badgeIcon = Icons.error_outline;
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(badgeIcon, color: badgeColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  lm.statusLabel,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: badgeColor,
                  ),
                ),
                const Spacer(),
                Chip(
                  label: Text(lm.isReady ? 'Active Engine' : 'Idle'),
                  backgroundColor: lm.isReady
                      ? Colors.green.withOpacity(0.15)
                      : colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow('Model Name', lm.modelName ?? 'None selected'),
            if (lm.modelBytes != null)
              _infoRow('File Size', _formatBytes(lm.modelBytes!)),
            if (lm.lastError != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Text(
                  lm.lastError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionsSection(LocalModelService lm, ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Model Controls',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.file_open),
              label: Text(
                lm.hasSelectedModel ? 'Choose Different Model' : 'Select GGUF Model File',
              ),
              onPressed: () async {
                try {
                  await lm.selectModel();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Model selection error: $e')),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Load into RAM'),
                    onPressed: lm.hasSelectedModel && !lm.isReady && lm.state != LocalModelState.loading
                        ? () async {
                            try {
                              await lm.loadModel();
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Load failed: $e')),
                                );
                              }
                            }
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Unload Model'),
                    onPressed: lm.isReady
                        ? () async {
                            try {
                              await lm.unloadModel();
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Unload error: $e')),
                                );
                              }
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInferenceTestSection(LocalModelService lm, ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology, size: 20),
                const SizedBox(width: 8),
                Text(
                  'On-Device Inference Self-Test',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Test the loaded model with real token generation. This executes directly against the local engine without cloud services.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _testPromptController,
              decoration: const InputDecoration(
                labelText: 'Test Prompt',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_isTesting ? 'Generating Tokens...' : 'Run Self-Test'),
              onPressed: lm.isReady && !_isTesting ? _runTest : null,
            ),
            if (_testOutput != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Generated Response:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(_testOutput!),
                  ],
                ),
              ),
            ],
            if (_testError != null) ...[
              const SizedBox(height: 12),
              Text(
                'Test Error: $_testError',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurationSection(LocalModelService lm, ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Generation & Hardware Settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Context Window Size'),
              subtitle: const Text('Maximum total tokens (prompt + output) held in memory'),
              trailing: DropdownButton<int>(
                value: lm.contextSize,
                onChanged: (val) {
                  if (val != null) lm.setContextSize(val);
                },
                items: const [
                  DropdownMenuItem(value: 1024, child: Text('1024 tokens')),
                  DropdownMenuItem(value: 2048, child: Text('2048 tokens (Recommended)')),
                  DropdownMenuItem(value: 4096, child: Text('4096 tokens')),
                ],
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Max Generation Tokens'),
              subtitle: const Text('Maximum output length per turn'),
              trailing: DropdownButton<int>(
                value: lm.maxTokens,
                onChanged: (val) {
                  if (val != null) lm.setMaxTokens(val);
                },
                items: const [
                  DropdownMenuItem(value: 128, child: Text('128 tokens')),
                  DropdownMenuItem(value: 256, child: Text('256 tokens')),
                  DropdownMenuItem(value: 512, child: Text('512 tokens')),
                ],
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('CPU Inference Threads'),
              subtitle: const Text('Number of CPU cores dedicated to llama.cpp'),
              trailing: DropdownButton<int>(
                value: lm.threads,
                onChanged: (val) {
                  if (val != null) lm.setThreads(val);
                },
                items: const [
                  DropdownMenuItem(value: 2, child: Text('2 cores')),
                  DropdownMenuItem(value: 4, child: Text('4 cores (Default)')),
                  DropdownMenuItem(value: 6, child: Text('6 cores')),
                  DropdownMenuItem(value: 8, child: Text('8 cores')),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Temperature: ${lm.temperature.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            Slider(
              value: lm.temperature,
              min: 0.1,
              max: 1.0,
              divisions: 9,
              label: lm.temperature.toStringAsFixed(2),
              onChanged: (val) => lm.setTemperature(val),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTechnicalDetailsSection(LocalModelService lm, ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Engine Metrics & Diagnostics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _infoRow('Status Details', lm.statusDetails),
            if (lm.loadedContextSize != null)
              _infoRow('Active Context Tokens', '${lm.loadedContextSize}'),
            if (lm.loadDuration != null)
              _infoRow('Model Load Duration', '${lm.loadDuration!.inMilliseconds} ms'),
            if (lm.timeToFirstToken != null)
              _infoRow('Time to First Token', '${lm.timeToFirstToken!.inMilliseconds} ms'),
            if (lm.lastGenerationDuration != null)
              _infoRow('Last Response Time', '${lm.lastGenerationDuration!.inMilliseconds} ms'),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearModel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Model Reference?'),
        content: const Text(
          'This will unload the model from memory and remove the reference from Lucy. Your model file on disk will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.localModel.clearModel();
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
