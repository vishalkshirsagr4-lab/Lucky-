import 'package:flutter/material.dart';
import '../services/agent_controller.dart';
import '../services/reminder_service.dart';

class RemindersScreen extends StatefulWidget {
  final AgentController controller;

  const RemindersScreen({super.key, required this.controller});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _showAddReminderDialog() async {
    final titleCtrl = TextEditingController();
    DateTime selectedDate = DateTime.now().add(const Duration(hours: 1));
    TimeOfDay selectedTime = TimeOfDay.fromDateTime(selectedDate);
    ReminderRecurrence recurrence = ReminderRecurrence.none;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Reminder'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'What to remind?',
                    hintText: 'e.g. Call dentist or take medicine',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Date & Time:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                          '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}',
                        ),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: selectedDate,
                            firstDate: DateTime.now().subtract(
                              const Duration(days: 1),
                            ),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (picked != null) {
                            setDialogState(() {
                              selectedDate = DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                                selectedTime.hour,
                                selectedTime.minute,
                              );
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.access_time, size: 16),
                        label: Text(
                          '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
                        ),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: ctx,
                            initialTime: selectedTime,
                          );
                          if (picked != null) {
                            setDialogState(() {
                              selectedTime = picked;
                              selectedDate = DateTime(
                                selectedDate.year,
                                selectedDate.month,
                                selectedDate.day,
                                picked.hour,
                                picked.minute,
                              );
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Recurrence:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                DropdownButton<ReminderRecurrence>(
                  value: recurrence,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: ReminderRecurrence.none,
                      child: Text('Does not repeat'),
                    ),
                    DropdownMenuItem(
                      value: ReminderRecurrence.daily,
                      child: Text('Every day'),
                    ),
                    DropdownMenuItem(
                      value: ReminderRecurrence.weekdays,
                      child: Text('Every weekday (Mon-Fri)'),
                    ),
                    DropdownMenuItem(
                      value: ReminderRecurrence.weekly,
                      child: Text('Every week'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => recurrence = val);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (titleCtrl.text.trim().isNotEmpty) {
                  Navigator.pop(dialogCtx, true);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result == true && titleCtrl.text.trim().isNotEmpty) {
      await widget.controller.reminderService.addReminder(
        title: titleCtrl.text.trim(),
        scheduledTime: selectedDate,
        recurrence: recurrence,
      );
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.controller.reminderService.pendingReminders;
    final completed = widget.controller.reminderService.completedReminders;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Reminders'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Pending (${pending.length})'),
            Tab(text: 'Completed (${completed.length})'),
          ],
        ),
        actions: [
          if (completed.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined),
              tooltip: 'Clear Completed',
              onPressed: () async {
                await widget.controller.reminderService
                    .clearCompletedReminders();
                setState(() {});
              },
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildList(pending, isPending: true, colorScheme: colorScheme),
          _buildList(completed, isPending: false, colorScheme: colorScheme),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddReminderDialog,
        icon: const Icon(Icons.alarm_add),
        label: const Text('New Reminder'),
      ),
    );
  }

  Widget _buildList(
    List<ReminderItem> list, {
    required bool isPending,
    required ColorScheme colorScheme,
  }) {
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPending ? Icons.notifications_none : Icons.task_alt,
              size: 64,
              color: colorScheme.outline.withOpacity(0.4),
            ),
            const SizedBox(height: 12),
            Text(
              isPending
                  ? 'No pending reminders.\nSay "Remind me to buy groceries at 6 PM".'
                  : 'No completed reminders.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final now = DateTime.now();

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final isOverdue = isPending && item.scheduledTime.isBefore(now);

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: Checkbox(
              value: item.isCompleted,
              onChanged: (_) async {
                await widget.controller.reminderService.toggleCompletion(
                  item.id,
                );
                setState(() {});
              },
            ),
            title: Text(
              item.title,
              style: TextStyle(
                decoration: item.isCompleted
                    ? TextDecoration.lineThrough
                    : null,
                fontWeight: isPending ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            subtitle: Row(
              children: [
                Icon(
                  Icons.access_time,
                  size: 13,
                  color: isOverdue ? Colors.redAccent : colorScheme.secondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '${item.scheduledTime.year}-${item.scheduledTime.month.toString().padLeft(2, '0')}-${item.scheduledTime.day.toString().padLeft(2, '0')} ${item.scheduledTime.hour.toString().padLeft(2, '0')}:${item.scheduledTime.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isOverdue
                        ? Colors.redAccent
                        : colorScheme.onSurfaceVariant,
                    fontWeight: isOverdue ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                if (isOverdue) ...[
                  const SizedBox(width: 6),
                  const Text(
                    '(Overdue)',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                if (item.recurrence != ReminderRecurrence.none) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.recurrence.name,
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete',
              onPressed: () async {
                await widget.controller.reminderService.deleteReminder(item.id);
                setState(() {});
              },
            ),
          ),
        );
      },
    );
  }
}
