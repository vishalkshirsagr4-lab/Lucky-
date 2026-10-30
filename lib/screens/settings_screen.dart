import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/agent_controller.dart';
import '../services/local_model_service.dart';
import 'model_manager_screen.dart';
import 'memories_screen.dart';
import 'reminders_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AgentController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Capabilities', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            _statusTile(
              context,
              'AI provider',
              '${controller.aiService.activeProviderStatus} · ${_providerDescription(controller.aiService.providerMode)} · '
                  '${controller.aiService.isConfigured ? 'Gemini key configured' : 'Gemini not configured'}',
              controller.aiService.activeProviderStatus == 'GEMINI'
                  ? Icons.cloud_done_outlined
                  : Icons.memory,
            ),
            _statusTile(
              context,
              'Local model',
              controller.aiService.localModelStatus,
              Icons.memory,
            ),
            _statusTile(
              context,
              'Speech recognition',
              controller.speechRecognitionReady
                  ? 'Device speech recognizer available; offline model and network behavior are not verified'
                  : 'Unavailable until the device speech recognizer is initialized',
              Icons.mic_none,
            ),
            _statusTile(
              context,
              'Microphone',
              controller.microphoneStatus,
              Icons.mic,
            ),
            _statusTile(
              context,
              'Wake-word detection',
              controller.wakeWordStatus,
              Icons.hearing_disabled,
            ),
            _statusTile(
              context,
              'Background listening',
              controller.backgroundListeningStatus,
              Icons.notifications_paused_outlined,
            ),
            const Divider(height: 32),
            Text(
              'AI provider and local model',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Provider mode'),
              subtitle: const Text(
                'Local Only never calls Gemini. Local First uses Gemini only when fallback and cloud consent are both enabled.',
              ),
              trailing: DropdownButton<AiProviderMode>(
                value: controller.aiService.providerMode,
                onChanged: (mode) async {
                  if (mode != null) await controller.setProviderMode(mode);
                },
                items: const [
                  DropdownMenuItem(
                    value: AiProviderMode.localOnly,
                    child: Text('Local Only'),
                  ),
                  DropdownMenuItem(
                    value: AiProviderMode.localFirst,
                    child: Text('Local First'),
                  ),
                  DropdownMenuItem(
                    value: AiProviderMode.cloudPreferred,
                    child: Text('Cloud Preferred'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow Gemini fallback'),
              subtitle: const Text(
                'Local First can use Gemini after local inference fails. Cloud data consent is also required.',
              ),
              value: controller.aiService.cloudFallbackEnabled,
              onChanged:
                  controller.aiService.providerMode == AiProviderMode.localOnly
                  ? null
                  : controller.setCloudFallbackEnabled,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow requests and screen data to Gemini'),
              subtitle: const Text(
                'When enabled, your command, screenshot, and accessibility text may be sent to Google in a cloud mode.',
              ),
              value: controller.aiService.allowGeminiData,
              onChanged: (enabled) async {
                if (!enabled) {
                  await controller.setAllowGeminiData(false);
                  return;
                }
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Allow cloud data?'),
                    content: const Text(
                      'Lucy may send your request, current screenshot, and accessibility text to Google Gemini when Cloud Preferred is selected or Local First fallback is enabled. Continue?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Allow'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await controller.setAllowGeminiData(true);
                }
              },
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GGUF model',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(controller.localModel.statusDetails),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Expanded(child: Text('Context size')),
                        DropdownButton<int>(
                          value: controller.localModel.contextSize,
                          onChanged: controller.localModel.isGenerating
                              ? null
                              : (value) async {
                                  if (value != null) {
                                    await controller.localModel.setContextSize(
                                      value,
                                    );
                                  }
                                },
                          items: const [
                            DropdownMenuItem(value: 1024, child: Text('1,024')),
                            DropdownMenuItem(value: 2048, child: Text('2,048')),
                            DropdownMenuItem(value: 4096, child: Text('4,096')),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      'CPU inference is enabled. Context changes apply the next time the model loads.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Row(
                      children: [
                        const Expanded(child: Text('Maximum response tokens')),
                        DropdownButton<int>(
                          value: controller.localModel.maxTokens,
                          onChanged: (value) async {
                            if (value != null) {
                              await controller.localModel.setMaxTokens(value);
                            }
                          },
                          items: const [
                            DropdownMenuItem(value: 128, child: Text('128')),
                            DropdownMenuItem(value: 256, child: Text('256')),
                            DropdownMenuItem(value: 512, child: Text('512')),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Expanded(child: Text('Temperature')),
                        DropdownButton<double>(
                          value: controller.localModel.temperature,
                          onChanged: (value) async {
                            if (value != null) {
                              await controller.localModel.setTemperature(value);
                            }
                          },
                          items: const [
                            DropdownMenuItem(value: 0.2, child: Text('0.2')),
                            DropdownMenuItem(value: 0.4, child: Text('0.4')),
                            DropdownMenuItem(value: 0.7, child: Text('0.7')),
                            DropdownMenuItem(value: 1.0, child: Text('1.0')),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              controller.localModel.isGenerating ||
                                  controller.localModel.state ==
                                      LocalModelState.loading ||
                                  controller.localModel.state ==
                                      LocalModelState.validating
                              ? null
                              : () async {
                                  try {
                                    await controller.selectLocalModel();
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(error.toString()),
                                        ),
                                      );
                                    }
                                  }
                                },
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Choose GGUF'),
                        ),
                        if (!controller.localModel.isReady)
                          FilledButton.icon(
                            onPressed:
                                controller.localModel.hasSelectedModel &&
                                    controller.localModel.state !=
                                        LocalModelState.loading &&
                                    !controller.localModel.isGenerating
                                ? () async {
                                    try {
                                      await controller.loadLocalModel();
                                    } catch (error) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(error.toString()),
                                          ),
                                        );
                                      }
                                    }
                                  }
                                : null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Load'),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: controller.localModel.isGenerating
                                ? null
                                : () async {
                                    try {
                                      await controller.unloadLocalModel();
                                    } catch (error) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(error.toString()),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('Unload'),
                          ),
                        FilledButton.tonalIcon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ModelManagerScreen(
                                localModel: controller.localModel,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.tune),
                          label: const Text('Model Manager'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 32),
            Text(
              'Assistant Features & Data',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('Local Memories'),
              subtitle: Text(
                '${controller.memoryService.memories.length} memories stored on-device',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MemoriesScreen(controller: controller),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Local Reminders'),
              subtitle: Text(
                '${controller.reminderService.pendingReminders.length} pending, ${controller.reminderService.completedReminders.length} completed',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RemindersScreen(controller: controller),
                ),
              ),
            ),
            const Divider(height: 32),
            Text('Voice', style: Theme.of(context).textTheme.titleLarge),
            ListTile(
              title: const Text('Speech language'),
              subtitle: const Text(
                'Affects device speech recognition and replies',
              ),
              trailing: DropdownButton<String>(
                value: controller.currentLang,
                onChanged: (value) {
                  if (value != null) controller.setLanguage(value);
                },
                items: const [
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'ja', child: Text('Japanese')),
                  DropdownMenuItem(value: 'ar', child: Text('Arabic')),
                ],
              ),
            ),
            ListTile(
              title: const Text('Speech rate'),
              subtitle: Slider(
                value: controller.speechRate,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: controller.speechRate.toStringAsFixed(1),
                onChanged: controller.setSpeechRate,
              ),
            ),
            ListTile(
              title: const Text('Follow-up conversation timeout'),
              subtitle: const Text(
                'Stops the current listening session after this much inactivity',
              ),
              trailing: DropdownButton<int>(
                value: controller.followupTimeout.inSeconds,
                onChanged: (seconds) {
                  if (seconds != null) {
                    controller.setFollowupTimeout(Duration(seconds: seconds));
                  }
                },
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 sec')),
                  DropdownMenuItem(value: 60, child: Text('1 min')),
                  DropdownMenuItem(value: 120, child: Text('2 min')),
                  DropdownMenuItem(value: 300, child: Text('5 min')),
                  DropdownMenuItem(value: 600, child: Text('10 min')),
                ],
              ),
            ),            const Divider(height: 32),

            Text(
              'Task agent limits (configurable)',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),

            _limitsSectionTile(
              context,
              'Actions per task',
              'Maximum device actions Lucy can run for one request. Raised limits can let a model fix errors, but they also extend a harmful sequence, so most people only raise this to recover from a real obstacle.',
              controller.maxActionsPerTask,
              [
                6, 12, 24, 36,
              ],
            ),
            _limitsSectionTile(
              context,
              'Reasoning steps',
              'Maximum model calls for one request. Fewer steps are faster and safer; more steps let Lucy recover from failures, but more steps also raise on-device cost and the chance of repeating an unnecessary action.',
              controller.maxInferencesPerTask,
              [
                4, 8, 12, 20,
              ],
            ),
            _limitsSectionTile(
              context,
              'Task time limit',
              'Total wall-clock limit for one request, after which Lucy stops automatically. Short limits end unrecoverable paths quickly; long limits help slow local models that need a few quiet moments.',
              controller.taskDeadline.inSeconds,
              [
                60, 120, 300, 600,
              ],
              isDuration: true,
            ),
            _limitsSectionTile(
              context,
              'Generation timeout',
              'One model generation is cancelled if it does not answer within this time, so a stuck local model never hangs the agent. Local GGUF models on small devices can need a little more time for their first token.',
              controller.inferenceTimeout.inSeconds,
              [
                20, 45, 60, 120, 180,
              ],
              isDuration: true,
            ),

            const Divider(height: 32),

            Text(
              'Privacy and battery',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const ListTile(
              leading: Icon(Icons.privacy_tip_outlined),
              title: Text('Microphone and screen privacy'),
              subtitle: Text(
                'Voice listening is started from the app and is not an always-on service. '
                'Gemini requests include your command and, for screen-aware tasks, may include a screenshot and accessibility tree. '
                'Conversation text is kept on this device; raw microphone recordings are not stored by Lucy.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.battery_saver_outlined),
              title: Text('Battery use'),
              subtitle: Text(
                'Manual speech recognition runs only during an active listening session. '
                'Continuous low-power monitoring is unavailable because this build has no wake-word engine.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.view_in_ar_outlined),
              title: Text('3D avatar'),
              subtitle: Text(
                'VRM/VRMA assets are present, but this build does not include a compatible renderer. '
                'No static thumbnail is presented as an animated avatar.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One row per tunable loop limit: what it caps, why it matters, and a
  /// dropdown of safe values. Each change is persisted by the controller.
  Widget _limitsSectionTile(
    BuildContext context,
    String title,
    String subtitle,
    int value,
    List<int> options, {
    bool isDuration = false,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: DropdownButton<int>(
        value: value,
        onChanged: (option) {
          if (option != null) {
            _onLimitsChanged(context, title, option);
          }
        },
        items: options.map((option) {
          final label = isDuration
              ? (option >= 60
                  ? '${option ~/ 60} min${option % 60 == 0 ? '' : ' ${option % 60}s'}'
                  : '${option}s')
              : '$option';
          return DropdownMenuItem(value: option, child: Text(label));
        }).toList(),
      ),
    );
  }

  void _onLimitsChanged(BuildContext context, String field, int value) {
    switch (field) {
      case 'Actions per task':
        controller.setMaxActionsPerTask(value);
      case 'Reasoning steps':
        controller.setMaxInferencesPerTask(value);
      case 'Task time limit':
        controller.setTaskDeadline(Duration(seconds: value));
      case 'Generation timeout':
        controller.setInferenceTimeout(Duration(seconds: value));
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$field set to $value.'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  String _providerDescription(AiProviderMode mode) => switch (mode) {
    AiProviderMode.localOnly => 'Local Only',
    AiProviderMode.localFirst => 'Local First',
    AiProviderMode.cloudPreferred => 'Cloud Preferred',
  };

  Widget _statusTile(
    BuildContext context,
    String title,
    String status,
    IconData icon,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Theme.of(context).colorScheme.secondary),
      title: Text(title),
      subtitle: Text(status),
    );
  }
}
