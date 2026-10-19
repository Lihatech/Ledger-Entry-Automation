import { useState, useEffect, useMemo } from 'react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import { getTasks, resolveIssue, acceptTask, flagIssue } from '../api/tasks';
import { formatDateTime } from '../utils/formatters';
import TaskModal from '../components/tasks/TaskModal';
import CompleteTaskModal from '../components/tasks/CompleteTaskModal';
import {
  Plus, RefreshCw, CheckCircle2, Clock, AlertTriangle,
  ListTodo, ChevronDown, ChevronUp, User, ClipboardList, Send,
  Paperclip, ExternalLink, FileText
} from 'lucide-react';

function ResolveModal({ task, onClose, onConfirm }) {
  const [actionType, setActionType] = useState('reopen');
  const [newDeadline, setNewDeadline] = useState('');
  const [instructions, setInstructions] = useState('');

  useEffect(() => {
    if (task?.deadline && actionType === 'extend') {
      const d = new Date(task.deadline);
      const tzoffset = (new Date()).getTimezoneOffset() * 60000;
      const localISOTime = (new Date(d - tzoffset)).toISOString().slice(0, 16);
      setNewDeadline(localISOTime);
    }
  }, [task, actionType]);

  if (!task) return null;

  return (
    <div className="modal-backdrop">
      <div className="modal-content" style={{ width: 400 }}>
        <h3 style={{ margin: '0 0 16px 0' }}>Resolve Issue</h3>
        <p style={{ fontSize: '0.85rem', color: 'var(--text-muted)', marginBottom: 20 }}>
          How do you want to handle the issue for task: <strong>{task.title}</strong>?
        </p>
        
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginBottom: 24 }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input type="radio" name="actionType" value="reopen" checked={actionType === 'reopen'} onChange={() => setActionType('reopen')} />
            Reopen (Keep existing deadline)
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input type="radio" name="actionType" value="extend" checked={actionType === 'extend'} onChange={() => setActionType('extend')} />
            Extend Task (Set new deadline)
          </label>
          {actionType === 'extend' && (
            <div style={{ marginLeft: 24 }}>
              <input type="datetime-local" className="form-input" value={newDeadline} onChange={e => setNewDeadline(e.target.value)} />
            </div>
          )}
          <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input type="radio" name="actionType" value="cancel" checked={actionType === 'cancel'} onChange={() => setActionType('cancel')} />
            Cancel Task
          </label>
        </div>

        {actionType !== 'cancel' && (
          <div className="form-group" style={{ marginBottom: 24 }}>
            <label className="form-label" style={{ fontSize: '0.8rem' }}>Additional Instructions (Optional)</label>
            <textarea
              className="form-textarea"
              placeholder="e.g. Please make sure to check the pressure gauge this time..."
              value={instructions}
              onChange={e => setInstructions(e.target.value)}
              style={{ minHeight: 60 }}
            />
          </div>
        )}

        <div className="modal-actions" style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <button className="btn btn-ghost" onClick={onClose}>Back</button>
          <button className="btn btn-primary" onClick={() => onConfirm(actionType, actionType === 'extend' ? new Date(newDeadline).toISOString() : null, instructions)}>
            Confirm
          </button>
        </div>
      </div>
    </div>
  );
}

function FlagIssueModal({ task, onClose, onConfirm }) {
  const [description, setDescription] = useState('');

  if (!task) return null;

  return (
    <div className="modal-backdrop">
      <div className="modal-content" style={{ width: 400 }}>
        <h3 style={{ margin: '0 0 16px 0' }}>Flag Issue</h3>
        <p style={{ fontSize: '0.85rem', color: 'var(--text-muted)', marginBottom: 20 }}>
          Please describe the issue preventing you from completing <strong>{task.title}</strong>:
        </p>
        
        <div className="form-group" style={{ marginBottom: 24 }}>
          <textarea
            className="form-textarea"
            placeholder="Describe the issue..."
            value={description}
            onChange={e => setDescription(e.target.value)}
            style={{ minHeight: 80 }}
            autoFocus
          />
        </div>

        <div className="modal-actions" style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button 
            className="btn btn-primary" 
            style={{ background: 'var(--accent-red)', border: 'none' }}
            onClick={() => onConfirm(description)}
            disabled={!description.trim()}
          >
            Submit Issue
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Shared Helpers ────────────────────────────────────────────────────────────

const STATUS_CONFIG = {
  pending:       { label: 'Pending',       badgeClass: 'badge-pending',  rowClass: '' },
  accepted:      { label: 'Accepted',      badgeClass: 'badge-progress', rowClass: '' },
  flagged_issue: { label: 'Issue Flagged', badgeClass: 'badge-ooc',      rowClass: 'row-ooc' },
  completed:     { label: 'Completed',     badgeClass: 'badge-ok',       rowClass: '' },
  cancelled:     { label: 'Cancelled',     badgeClass: 'badge-manual',   rowClass: '' },
};

function getDeadlineInfo(deadlineStr, status) {
  if (!deadlineStr) return { label: '-', urgent: false, overdue: false };
  const now = new Date();
  const dl = new Date(deadlineStr);
  const diffMs = dl - now;
  const diffMins = diffMs / 60000;
  
  const isFinished = status === 'completed' || status === 'cancelled';
  const overdue = !isFinished && diffMs < 0;
  const urgent = !isFinished && !overdue && diffMins <= 60;
  
  return { label: formatDateTime(deadlineStr), urgent, overdue };
}

function DeadlinePill({ deadlineStr, status }) {
  const { label, urgent, overdue } = getDeadlineInfo(deadlineStr, status);
  let cls = 'badge badge-manual';
  if (overdue) cls = 'badge badge-ooc';
  else if (urgent) cls = 'badge badge-pending';
  return <span className={cls}>{overdue ? 'OVERDUE · ' : urgent ? 'DUE SOON · ' : ''}{label}</span>;
}

// Expandable issue row used in all table views
function TaskRow({ task, currentUser, onResolve, onAccept, onComplete, onFlagIssue, showAllocatedBy = true }) {
  const [expanded, setExpanded] = useState(false);
  const [descExpanded, setDescExpanded] = useState(false);
  const [attachmentsExpanded, setAttachmentsExpanded] = useState(false);
  const cfg = STATUS_CONFIG[task.status] || STATUS_CONFIG.pending;
  const isAllocator = can(currentUser, 'tasks.allocate') &&
    (task.allocated_by?.id === currentUser?.id || can(currentUser, 'tasks.manage_all'));
  const isAssignee = task.allocated_to?.id === currentUser?.id;

  const needsExpansion = task.description && (task.description.length > 40 || task.description.includes('\n'));

  return (
    <>
      <tr className={cfg.rowClass}>
        <td style={{ verticalAlign: 'top' }}>
          <div style={{ fontWeight: 600, color: 'var(--text-primary)', marginBottom: 4 }}>{task.title}</div>
          <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)', maxWidth: 280 }}>
            <div style={{ 
              overflow: 'hidden', 
              textOverflow: 'ellipsis', 
              whiteSpace: descExpanded ? 'pre-wrap' : 'nowrap'
            }}>
              {task.description}
            </div>
            {needsExpansion && (
              <button 
                onClick={() => setDescExpanded(!descExpanded)}
                style={{ background: 'none', border: 'none', color: 'var(--accent-blue)', fontSize: '0.7rem', padding: 0, marginTop: 4, cursor: 'pointer', fontWeight: 600 }}
              >
                {descExpanded ? 'Show less' : 'Read more'}
              </button>
            )}
          </div>
        </td>
        {showAllocatedBy && (
          <td>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <User size={12} style={{ color: 'var(--text-muted)' }} />
              <span>{task.allocated_by?.first_name} {task.allocated_by?.last_name}</span>
            </div>
            <div style={{ fontSize: '0.72rem', color: 'var(--text-muted)' }}>@{task.allocated_by?.username}</div>
          </td>
        )}
        <td>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <User size={12} style={{ color: 'var(--accent-blue)' }} />
            <span style={{ color: 'var(--text-primary)' }}>{task.allocated_to?.first_name} {task.allocated_to?.last_name}</span>
          </div>
          <div style={{ fontSize: '0.72rem', color: 'var(--text-muted)' }}>@{task.allocated_to?.username}</div>
        </td>
        <td><DeadlinePill deadlineStr={task.deadline} status={task.status} /></td>
        <td><span className={`badge ${cfg.badgeClass}`}>{cfg.label}</span></td>
        <td style={{ textAlign: 'right' }}>
          {isAssignee && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginBottom: 4 }}>
              {task.status === 'pending' && (
                <button className="btn btn-sm" style={{ background: 'var(--accent-blue)', color: '#fff', border: 'none' }} onClick={() => onAccept(task)}>
                  Accept
                </button>
              )}
              {task.status === 'accepted' && (
                <button className="btn btn-sm" style={{ background: 'var(--accent-green)', color: '#fff', border: 'none' }} onClick={() => onComplete(task)}>
                  Complete
                </button>
              )}
              {(task.status === 'pending' || task.status === 'accepted') && (
                <button className="btn btn-sm" style={{ background: 'transparent', border: '1px solid var(--accent-red)', color: 'var(--accent-red)' }} onClick={() => onFlagIssue(task)}>
                  Flag Issue
                </button>
              )}
            </div>
          )}
          {task.status === 'flagged_issue' && isAllocator && (
            <button className="btn btn-ghost btn-sm" onClick={() => setExpanded(v => !v)} style={{ gap: 4 }}>
              {expanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
              {expanded ? 'Hide' : 'View Issue'}
            </button>
          )}
          {task.status === 'completed' && (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 12 }}>
              {isAllocator && task.attachments?.length > 0 && (
                <button 
                  className="btn btn-ghost btn-sm" 
                  onClick={() => setAttachmentsExpanded(v => !v)} 
                  style={{ gap: 4, fontSize: '0.75rem', padding: '4px 10px', background: 'var(--bg-elevated)', border: '1px solid var(--border)' }}
                >
                  <Paperclip size={12} />
                  {attachmentsExpanded ? 'Hide Files' : `View Files (${task.attachments.length})`}
                  {attachmentsExpanded ? <ChevronUp size={14} style={{ marginLeft: 2 }} /> : <ChevronDown size={14} style={{ marginLeft: 2 }} />}
                </button>
              )}
              <span style={{ color: 'var(--accent-green)', fontSize: '0.8rem', display: 'flex', alignItems: 'center', gap: 4, fontWeight: 600 }}>
                <CheckCircle2 size={15} /> Done
              </span>
            </div>
          )}
        </td>
      </tr>
      {expanded && task.status === 'flagged_issue' && isAllocator && (
        <tr style={{ background: 'rgba(239,68,68,0.04)' }}>
          <td colSpan={showAllocatedBy ? 6 : 5} style={{ padding: '12px 16px' }}>
            <div style={{
              display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16,
              background: 'rgba(239,68,68,0.07)', border: '1px solid rgba(239,68,68,0.2)',
              borderRadius: 8, padding: '12px 16px'
            }}>
              <div>
                <div style={{ fontSize: '0.7rem', fontWeight: 700, color: '#ef4444', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Issue Description
                </div>
                <div style={{ color: 'var(--text-primary)', fontSize: '0.85rem' }}>{task.issue_description}</div>
              </div>
              <button className="btn btn-primary btn-sm" onClick={() => onResolve(task)} style={{ flexShrink: 0 }}>
                <CheckCircle2 size={13} /> Resolve &amp; Reopen
              </button>
            </div>
          </td>
        </tr>
      )}
      {attachmentsExpanded && task.status === 'completed' && isAllocator && task.attachments?.length > 0 && (
        <tr style={{ background: 'color-mix(in srgb, var(--accent-green) 4%, transparent)' }}>
          <td colSpan={showAllocatedBy ? 6 : 5} style={{ padding: '12px 16px' }}>
            <div style={{
              background: 'color-mix(in srgb, var(--accent-green) 6%, transparent)',
              border: '1px solid color-mix(in srgb, var(--accent-green) 25%, transparent)',
              borderRadius: 8, padding: '12px 16px'
            }}>
              <div style={{ fontSize: '0.7rem', fontWeight: 700, color: 'var(--accent-green)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 10 }}>
                Completion Attachments ({task.attachments.length})
              </div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
                {task.attachments.map(att => {
                  const isImage = att.content_type.startsWith('image/');
                  const sizeMB = att.file_size < 1024 * 1024
                    ? `${(att.file_size / 1024).toFixed(1)} KB`
                    : `${(att.file_size / (1024 * 1024)).toFixed(1)} MB`;
                  return (
                    <a
                      key={att.id}
                      href={att.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      style={{
                        display: 'flex', alignItems: 'center', gap: 8,
                        padding: '6px 10px',
                        background: 'var(--bg-elevated)',
                        border: '1px solid var(--border)',
                        borderRadius: 8,
                        textDecoration: 'none',
                        color: 'var(--text-primary)',
                        minWidth: 160, maxWidth: 240,
                        transition: 'border-color 0.15s',
                      }}
                      title={att.file_name}
                    >
                      {isImage ? (
                        <img
                          src={att.url}
                          alt={att.file_name}
                          style={{ width: 36, height: 36, objectFit: 'cover', borderRadius: 4, flexShrink: 0 }}
                        />
                      ) : (
                        <div style={{
                          width: 36, height: 36, borderRadius: 4, flexShrink: 0,
                          background: 'var(--bg-card)',
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                        }}>
                          <FileText size={18} color="var(--text-muted)" />
                        </div>
                      )}
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: '0.78rem', fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {att.file_name}
                        </div>
                        <div style={{ fontSize: '0.68rem', color: 'var(--text-muted)' }}>{sizeMB}</div>
                      </div>
                      <ExternalLink size={12} color="var(--text-muted)" style={{ flexShrink: 0 }} />
                    </a>
                  );
                })}
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

// ─── ADMIN VIEW: Full analytics + all tasks ────────────────────────────────────

function AdminTasksView({ tasks, loading, refreshing, onRefresh, onAllocate, onResolve, onAccept, onComplete, onFlagIssue, currentUser }) {
  const [statusFilter, setStatusFilter] = useState('all');
  const [viewTab, setViewTab] = useState('all');

  const stats = {
    total:     tasks.length,
    pending:   tasks.filter(t => t.status === 'pending').length,
    accepted:  tasks.filter(t => t.status === 'accepted').length,
    flagged:   tasks.filter(t => t.status === 'flagged_issue').length,
    completed: tasks.filter(t => t.status === 'completed').length,
  };

  const tabs = [
    { key: 'all',      label: 'All Tasks',       count: tasks.length },
    { key: 'mine',     label: 'Allocated by Me', count: tasks.filter(t => t.allocated_by?.id === currentUser?.id).length },
    { key: 'assigned', label: 'Assigned to Me',  count: tasks.filter(t => t.allocated_to?.id === currentUser?.id).length },
  ];

  const filteredTasks = useMemo(() => {
    let list = tasks;
    if (viewTab === 'mine') list = list.filter(t => t.allocated_by?.id === currentUser?.id);
    if (viewTab === 'assigned') list = list.filter(t => t.allocated_to?.id === currentUser?.id);
    if (statusFilter !== 'all') list = list.filter(t => t.status === statusFilter);
    return list;
  }, [tasks, viewTab, statusFilter, currentUser]);

  return (
    <>
      {/* Stats Cards */}
      <div className="stat-grid" style={{ gridTemplateColumns: 'repeat(4, 1fr)', marginBottom: 24 }}>
        <div className="stat-card" style={{ '--stat-accent': 'var(--accent-blue)' }}>
          <div className="stat-label">Total Tasks</div>
          <div className="stat-value">{stats.total}</div>
          <div className="stat-sub"><ListTodo size={12} /> All tasks</div>
        </div>
        <div className="stat-card" style={{ '--stat-accent': '#f59e0b' }}>
          <div className="stat-label">In Progress</div>
          <div className="stat-value" style={{ color: '#f59e0b' }}>{stats.pending + stats.accepted}</div>
          <div className="stat-sub"><Clock size={12} /> Pending + Accepted</div>
        </div>
        <div className={`stat-card${stats.flagged > 0 ? ' alert' : ''}`} style={{ '--stat-accent': 'var(--accent-red)' }}>
          <div className="stat-label">Flagged Issues</div>
          <div className="stat-value" style={{ color: 'var(--accent-red)' }}>{stats.flagged}</div>
          <div className="stat-sub"><AlertTriangle size={12} /> Needs resolution</div>
        </div>
        <div className="stat-card" style={{ '--stat-accent': 'var(--accent-green)' }}>
          <div className="stat-label">Completed</div>
          <div className="stat-value" style={{ color: 'var(--accent-green)' }}>{stats.completed}</div>
          <div className="stat-sub"><CheckCircle2 size={12} /> Finished</div>
        </div>
      </div>

      <div className="card">
        {/* Toolbar */}
        <div className="section-header" style={{ marginBottom: 0, paddingBottom: 16, borderBottom: '1px solid var(--border)', flexWrap: 'wrap', gap: 12 }}>
          <div style={{ display: 'flex', gap: 4 }}>
            {tabs.map(tab => (
              <button
                key={tab.key}
                onClick={() => setViewTab(tab.key)}
                className="btn btn-sm"
                style={{
                  background: viewTab === tab.key ? 'var(--accent-blue)' : 'var(--bg-elevated)',
                  color: viewTab === tab.key ? '#fff' : 'var(--text-secondary)',
                  border: viewTab === tab.key ? 'none' : '1px solid var(--border)',
                }}
              >
                {tab.label}
                <span style={{ marginLeft: 4, background: viewTab === tab.key ? 'rgba(255,255,255,0.25)' : 'var(--bg-hover)', borderRadius: 10, padding: '1px 6px', fontSize: '0.68rem', fontWeight: 700 }}>
                  {tab.count}
                </span>
              </button>
            ))}
          </div>
          <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginLeft: 'auto' }}>
            <select className="form-select" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} style={{ width: 160, padding: '6px 12px' }}>
              <option value="all">All Statuses</option>
              <option value="pending">Pending</option>
              <option value="accepted">Accepted</option>
              <option value="flagged_issue">Flagged Issue</option>
              <option value="completed">Completed</option>
            </select>
            <button className="btn btn-ghost btn-sm" onClick={onRefresh} disabled={refreshing} title="Refresh">
              <RefreshCw size={14} style={{ animation: refreshing ? 'spin 1s linear infinite' : 'none' }} />
            </button>
            {can(currentUser, 'tasks.allocate') && <button className="btn btn-primary" onClick={onAllocate}>
              <Plus size={16} /> Allocate Task
            </button>}
          </div>
        </div>

        {/* Table */}
        {loading ? <LoadingSpinner message="Loading tasks..." /> : filteredTasks.length === 0 ? (
          <div className="empty-state" style={{ padding: '48px 24px' }}>
            <div className="empty-state-text">
              {statusFilter !== 'all' || viewTab !== 'all' ? 'No tasks match your current filters.' : 'No tasks yet. Click "Allocate Task" to create the first one.'}
            </div>
          </div>
        ) : (
          <div className="table-wrapper" style={{ borderRadius: 0, border: 'none' }}>
            <table>
              <thead>
                <tr>
                  <th>Task</th>
                  <th>Allocated By</th>
                  <th>Assigned To</th>
                  <th>Deadline</th>
                  <th>Status</th>
                  <th style={{ textAlign: 'right' }}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {filteredTasks.map(task => (
                  <TaskRow key={task.id} task={task} currentUser={currentUser} onResolve={onResolve} onAccept={onAccept} onComplete={onComplete} onFlagIssue={onFlagIssue} showAllocatedBy={true} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}

// ─── SUPERVISOR / INSPECTOR VIEW: My tasks only + allocate ─────────────────────

function UserTasksView({ tasks, loading, refreshing, onRefresh, onAllocate, onResolve, onAccept, onComplete, onFlagIssue, currentUser }) {
  const [activeTab, setActiveTab] = useState('assigned');

  const assignedToMe = useMemo(() => tasks.filter(t => t.allocated_to?.id === currentUser?.id), [tasks, currentUser]);
  const allocatedByMe = useMemo(() => tasks.filter(t => t.allocated_by?.id === currentUser?.id), [tasks, currentUser]);

  const displayTasks = activeTab === 'assigned' ? assignedToMe : allocatedByMe;

  return (
    <div className="card">
      {/* Toolbar */}
      <div className="section-header" style={{ marginBottom: 0, paddingBottom: 16, borderBottom: '1px solid var(--border)', flexWrap: 'wrap', gap: 12 }}>
        {/* Tabs */}
        <div style={{ display: 'flex', gap: 4 }}>
          <button
            onClick={() => setActiveTab('assigned')}
            className="btn btn-sm"
            style={{
              background: activeTab === 'assigned' ? 'var(--accent-blue)' : 'var(--bg-elevated)',
              color: activeTab === 'assigned' ? '#fff' : 'var(--text-secondary)',
              border: activeTab === 'assigned' ? 'none' : '1px solid var(--border)',
              display: 'flex', alignItems: 'center', gap: 6,
            }}
          >
            <ClipboardList size={13} />
            Assigned to Me
            <span style={{ marginLeft: 2, background: activeTab === 'assigned' ? 'rgba(255,255,255,0.25)' : 'var(--bg-hover)', borderRadius: 10, padding: '1px 6px', fontSize: '0.68rem', fontWeight: 700 }}>
              {assignedToMe.length}
            </span>
          </button>
          <button
            onClick={() => setActiveTab('mine')}
            className="btn btn-sm"
            style={{
              background: activeTab === 'mine' ? 'var(--accent-blue)' : 'var(--bg-elevated)',
              color: activeTab === 'mine' ? '#fff' : 'var(--text-secondary)',
              border: activeTab === 'mine' ? 'none' : '1px solid var(--border)',
              display: 'flex', alignItems: 'center', gap: 6,
            }}
          >
            <Send size={13} />
            Allocated by Me
            <span style={{ marginLeft: 2, background: activeTab === 'mine' ? 'rgba(255,255,255,0.25)' : 'var(--bg-hover)', borderRadius: 10, padding: '1px 6px', fontSize: '0.68rem', fontWeight: 700 }}>
              {allocatedByMe.length}
            </span>
          </button>
        </div>

        {/* Right controls */}
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginLeft: 'auto' }}>
          <button className="btn btn-ghost btn-sm" onClick={onRefresh} disabled={refreshing} title="Refresh">
            <RefreshCw size={14} style={{ animation: refreshing ? 'spin 1s linear infinite' : 'none' }} />
          </button>
          {can(currentUser, 'tasks.allocate') && <button className="btn btn-primary" onClick={onAllocate}>
            <Plus size={16} /> Allocate Task
          </button>}
        </div>
      </div>

      {/* Table */}
      {loading ? <LoadingSpinner message="Loading tasks..." /> : displayTasks.length === 0 ? (
        <div className="empty-state" style={{ padding: '48px 24px' }}>
          <div className="empty-state-text">
            {activeTab === 'assigned'
              ? 'No tasks have been assigned to you yet.'
              : 'You have not allocated any tasks yet. Click "Allocate Task" to create one.'}
          </div>
        </div>
      ) : (
        <div className="table-wrapper" style={{ borderRadius: 0, border: 'none' }}>
          <table>
            <thead>
              <tr>
                <th>Task</th>
                {activeTab === 'mine' && <th>Assigned To</th>}
                {activeTab === 'assigned' && <th>Allocated By</th>}
                <th>Deadline</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {displayTasks.map(task => (
                <TaskRow
                  key={task.id}
                  task={task}
                  currentUser={currentUser}
                  onResolve={onResolve}
                  onAccept={onAccept}
                  onComplete={onComplete}
                  onFlagIssue={onFlagIssue}
                  showAllocatedBy={activeTab === 'assigned'}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ─── MAIN PAGE ─────────────────────────────────────────────────────────────────

export default function TasksPage() {
  const { user } = useAuth();
  const [tasks, setTasks] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [showModal, setShowModal] = useState(false);
  const [resolvingTask, setResolvingTask] = useState(null);
  const [flaggingTask, setFlaggingTask] = useState(null);
  const [completeTaskTarget, setCompleteTaskTarget] = useState(null);

  const fetchTasks = async (silent = false) => {
    if (!silent) setLoading(true);
    else setRefreshing(true);
    try {
      const res = await getTasks();
      setTasks(res.data?.results ?? res.data ?? []);
    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => { fetchTasks(); }, []);

  const handleResolveIssue = async (actionType, newDeadline, instructions) => {
    if (!resolvingTask) return;
    try {
      await resolveIssue(resolvingTask.id, { 
        action: actionType, 
        new_deadline: newDeadline,
        instructions: instructions 
      });
      fetchTasks(true);
      setResolvingTask(null);
    } catch (err) {
      alert(err.response?.data?.detail || 'Failed to resolve issue');
    }
  };

  const handleAcceptTask = async (task) => {
    try {
      await acceptTask(task.id);
      fetchTasks(true);
    } catch (err) {
      alert(err.response?.data?.detail || 'Failed to accept task');
    }
  };

  const handleCompleteTask = (task) => {
    setCompleteTaskTarget(task);
  };

  const handleFlagIssueSubmit = async (description) => {
    if (!flaggingTask) return;
    try {
      await flagIssue(flaggingTask.id, description);
      fetchTasks(true);
      setFlaggingTask(null);
    } catch (err) {
      alert(err.response?.data?.detail || 'Failed to flag issue');
    }
  };

  return (
    <div className="page-container">
      <Header title="Tasks Management" />
      
      <div className="page-content" style={{ padding: '24px' }}>
        <Breadcrumbs items={[{ label: 'Tasks' }]} />
        {can(user, 'tasks.view_all') ? (
          <AdminTasksView
            tasks={tasks}
            loading={loading}
            refreshing={refreshing}
            onRefresh={() => fetchTasks(true)}
            onAllocate={() => setShowModal(true)}
            onResolve={task => setResolvingTask(task)}
            onAccept={handleAcceptTask}
            onComplete={handleCompleteTask}
            onFlagIssue={task => setFlaggingTask(task)}
            currentUser={user}
          />
        ) : (
          <UserTasksView
            tasks={tasks}
            loading={loading}
            refreshing={refreshing}
            onRefresh={() => fetchTasks(true)}
            onAllocate={() => setShowModal(true)}
            onResolve={task => setResolvingTask(task)}
            onAccept={handleAcceptTask}
            onComplete={handleCompleteTask}
            onFlagIssue={task => setFlaggingTask(task)}
            currentUser={user}
          />
        )}
      </div>

      {showModal && (
        <TaskModal
          isOpen={showModal}
          onClose={() => setShowModal(false)}
          onTaskCreated={() => { fetchTasks(true); setShowModal(false); }}
        />
      )}
      
      {resolvingTask && (
        <ResolveModal 
          task={resolvingTask} 
          onClose={() => setResolvingTask(null)}
          onConfirm={handleResolveIssue}
        />
      )}

      {flaggingTask && (
        <FlagIssueModal
          task={flaggingTask}
          onClose={() => setFlaggingTask(null)}
          onConfirm={handleFlagIssueSubmit}
        />
      )}

      {completeTaskTarget && (
        <CompleteTaskModal
          task={completeTaskTarget}
          onClose={() => setCompleteTaskTarget(null)}
          onCompleted={() => { setCompleteTaskTarget(null); fetchTasks(true); }}
        />
      )}
    </div>
  );
}
