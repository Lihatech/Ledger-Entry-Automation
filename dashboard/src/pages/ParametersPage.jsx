import { useState, useEffect, useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import AdminParametersView from '../components/parameters/AdminParametersView';
import {
  getParts,
  createPart,
  updatePart,
  deletePart,
  getPartTemplates,
  createTemplate,
  updateTemplate,
  deleteTemplate,
  publishTemplate,
  submitTemplateReview,
  reviewTemplateAction,
  approveTemplateAction,
  getTemplateDCRs,
  submitTemplateDCR,
  reviewTemplateDCR,
  approveTemplateDCR,
  getTemplateParameters,
  createParameter,
  updateParameter,
  deleteParameter,
  getProcessParameters,
  createProcessParameter,
  updateProcessParameter,
  deleteProcessParameter,
} from '../api/parts';
import {
  Shield,
  FileText,
  Eye,
  CheckCircle2,
  AlertTriangle,
  UserCheck,
  Plus,
  Lock,
  RefreshCw,
  X,
  Clock,
  Edit3,
  Trash2,
  Sliders,
  ChevronRight,
  ArrowRight,
  Ban,
  Send,
  Settings,
  Check,
  History,
  FileSpreadsheet,
} from 'lucide-react';
import { getUsers } from '../api/users';
import api from '../api/axios';
import LoadingSpinner from '../components/common/LoadingSpinner';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { showAccessDenied } from '../components/common/AccessDeniedModal';

const extractErrorMessage = (err, fallback) => {
  if (!err.response?.data) return fallback;
  const data = err.response.data;
  if (typeof data === 'string') return data;
  if (data.error) return data.error;
  if (data.detail) return data.detail;
  if (typeof data === 'object') {
    return Object.entries(data)
      .map(([key, val]) => `${key.replace('_', ' ')}: ${Array.isArray(val) ? val.join(', ') : val}`)
      .join(' | ');
  }
  return fallback;
};

const formatSpecification = (spec) => {
  if (!spec) return '-';
  if (typeof spec === 'string') return spec;
  if (typeof spec === 'number') return String(spec);
  if (typeof spec === 'object') {
    if (spec.nominal_value !== undefined && spec.nominal_value !== null) {
      let text = `Nominal: ${spec.nominal_value}`;
      if (spec.unit) text += ` ${spec.unit}`;
      if (spec.upper_tolerance !== undefined || spec.lower_tolerance !== undefined) {
        const ut = spec.upper_tolerance ?? 0;
        const lt = spec.lower_tolerance ?? 0;
        const uStr = String(ut).startsWith('+') ? ut : `+${ut}`;
        const lStr = String(lt);
        text += `, Tol: ${uStr} / ${lStr}`;
      }
      return text;
    }
    if (spec.specification) return String(spec.specification);
    try {
      const entries = Object.entries(spec);
      if (entries.length === 0) return '-';
      return entries
        .map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`)
        .join(', ');
    } catch {
      return JSON.stringify(spec);
    }
  }
  return String(spec);
};

export default function ParametersPage() {
  const { user } = useAuth();
  const [searchParams] = useSearchParams();
  const targetOpId = searchParams.get('operation') || searchParams.get('template');
  const targetPartId = searchParams.get('part');
  const targetMachineId = searchParams.get('machine');
  const targetTab = searchParams.get('tab');
  const targetDcrId = searchParams.get('dcr');
  const isAdmin = can(user, 'development.parameters.manage');
  const requireManageAccess = (action = 'edit master database records') => {
    if (isAdmin) return true;
    showAccessDenied(`You have view-only access to the Master Database. Manage permission is required to ${action}.`);
    return false;
  };
  const [adminTab, setAdminTab] = useState('builder'); // 'builder' or 'audit'

  const [machines, setMachines] = useState([]);
  const [selectedMachine, setSelectedMachine] = useState(null);

  const [parts, setParts] = useState([]);
  const [selectedPart, setSelectedPart] = useState(null);

  const [templates, setTemplates] = useState([]);
  const [selectedTemplate, setSelectedTemplate] = useState(null);

  const [parameters, setParameters] = useState([]);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [successMsg, setSuccessMsg] = useState('');
  const [activeParamTab, setActiveParamTab] = useState('product'); // 'product', 'process'

  // Modals
  const [showAddMachineModal, setShowAddMachineModal] = useState(false);
  const [editingMachine, setEditingMachine] = useState(null);
  const [machineForm, setMachineForm] = useState({ machine_code: '', name: '', machine_type: 'CNC' });

  const [showAddPartModal, setShowAddPartModal] = useState(false);
  const [editingPart, setEditingPart] = useState(null);
  const [partForm, setPartForm] = useState({
    part_number: '',
    part_name: '',
    drawing_number: '',
    revision: 'A',
    description: '',
  });

  const [showAddOpModal, setShowAddOpModal] = useState(false);
  const [newOpName, setNewOpName] = useState('');
  const [newOpType, setNewOpType] = useState('first_piece');
  const [newOpTargetCount, setNewOpTargetCount] = useState(10);
  const [newOpCycleTime, setNewOpCycleTime] = useState('');

  const [showEditTargetModal, setShowEditTargetModal] = useState(false);
  const [editTargetCount, setEditTargetCount] = useState(10);
  const [editCycleTime, setEditCycleTime] = useState('');

  const [showPublishModal, setShowPublishModal] = useState(false);
  const [isPublishing, setIsPublishing] = useState(false);

  // Sign-Off Workflow States (Reviewer & Approver Governance)
  const [assignableUsers, setAssignableUsers] = useState([]);
  const eligibleSignoffUsers = useMemo(
    () => assignableUsers.filter((u) => String(u.id) !== String(user?.id)),
    [assignableUsers, user]
  );

  const [showSubmitReviewModal, setShowSubmitReviewModal] = useState(false);
  const [submitReviewForm, setSubmitReviewForm] = useState({
    assigned_reviewer: '',
    assigned_approver: '',
    notes: '',
  });
  const [isSubmittingReview, setIsSubmittingReview] = useState(false);

  const [showReviewModal, setShowReviewModal] = useState(false);
  const [reviewActionForm, setReviewActionForm] = useState({
    action: 'recommend', // 'recommend' | 'reject'
    comments: '',
  });
  const [isProcessingReview, setIsProcessingReview] = useState(false);

  const [showApproveModal, setShowApproveModal] = useState(false);
  const [approveActionForm, setApproveActionForm] = useState({
    action: 'approve', // 'approve' | 'reject'
    comments: '',
  });
  const [isProcessingApprove, setIsProcessingApprove] = useState(false);

  // Document Change Request (DCR) States: Form DKI/MR/F/05
  const [templateDCRs, setTemplateDCRs] = useState([]);
  const [loadingDCRs, setLoadingDCRs] = useState(false);
  const [showDCRModal, setShowDCRModal] = useState(false);
  const [dcrForm, setDcrForm] = useState({
    change_type: 'modification', // 'modification', 'addition', 'deletion'
    target_type: 'product', // 'product' or 'process'
    target_param_id: '',
    parameter_code: '',
    parameter_name: '',
    current_specification: '',
    proposed_specification: '',
    basis_for_change: '',
    assigned_reviewer: '',
    assigned_approver: '',
  });
  const [isSubmittingDCR, setIsSubmittingDCR] = useState(false);

  const [showDCRReviewModal, setShowDCRReviewModal] = useState(false);
  const [selectedDCR, setSelectedDCR] = useState(null);
  const [dcrReviewForm, setDcrReviewForm] = useState({
    action: 'recommend', // 'recommend' | 'reject'
    remarks: '',
  });
  const [isProcessingDCRReview, setIsProcessingDCRReview] = useState(false);

  const [showDCRApproveModal, setShowDCRApproveModal] = useState(false);
  const [dcrApproveForm, setDcrApproveForm] = useState({
    action: 'approve', // 'approve' | 'reject'
    remarks: '',
  });
  const [isProcessingDCRApprove, setIsProcessingDCRApprove] = useState(false);

  const [viewMode, setViewMode] = useState('blocks'); // 'blocks' | 'table'
  const [ruleMode, setRuleMode] = useState('rule1'); // 'rule1', 'rule2', 'rule3'
  const [showAddParamModal, setShowAddParamModal] = useState(false);
  const [editingParam, setEditingParam] = useState(null);
  const [paramForm, setParamForm] = useState({
    parameter_code: '',
    parameter_name: '',
    nominal_value: '10.00',
    upper_tolerance: '0.10',
    lower_tolerance: '-0.10',
    unit: 'mm',
    measurement_type: 'dimensional',
    is_critical: false,
    sequence_order: 1,
    voice_prompt: '',
    measurement_technique: '',
    sample_size: '',
    control_method: '',
  });

  // Fetch Users for Reviewer / Approver assignments
  useEffect(() => {
    const fetchUsers = async () => {
      try {
        const res = await getUsers();
        const loaded = res.data?.results ?? (Array.isArray(res.data) ? res.data : []);
        setAssignableUsers(loaded);
      } catch (err) {
        console.error('Failed to load assignable users for sign-off workflow:', err);
      }
    };
    fetchUsers();
  }, []);

  // Fetch DCRs for Selected Template (Form DKI/MR/F/05 Log)
  const loadTemplateDCRs = useCallback(async () => {
    if (!selectedTemplate) {
      setTemplateDCRs([]);
      return;
    }
    setLoadingDCRs(true);
    try {
      const res = await getTemplateDCRs(selectedTemplate.id);
      const data = res.data?.results ?? (Array.isArray(res.data) ? res.data : []);
      setTemplateDCRs(data);
    } catch (err) {
      console.error('Failed to load template DCRs:', err);
    } finally {
      setLoadingDCRs(false);
    }
  }, [selectedTemplate]);

  useEffect(() => {
    if (selectedTemplate) {
      loadTemplateDCRs();
    } else {
      setTemplateDCRs([]);
    }
  }, [selectedTemplate, loadTemplateDCRs]);

  // Auto-scroll / open target DCR if requested in URL params
  useEffect(() => {
    if ((targetTab === 'dcr' || targetDcrId) && templateDCRs.length > 0) {
      const el = document.getElementById('dcr-section');
      if (el) {
        el.scrollIntoView({ behavior: 'smooth' });
      }
      if (targetDcrId) {
        const found = templateDCRs.find(d => String(d.id) === String(targetDcrId));
        if (found) {
          if (found.status === 'awaiting_review' && can(user, 'development.parameters.review')) {
            setSelectedDCR(found);
            setShowDCRReviewModal(true);
          } else if (found.status === 'reviewed' && can(user, 'development.parameters.approve')) {
            setSelectedDCR(found);
            setShowDCRApproveModal(true);
          }
        }
      }
    }
  }, [templateDCRs, targetTab, targetDcrId, user]);

  // 1. Fetch Machines
  const loadMachines = useCallback(async () => {
    try {
      const res = await api.get('/api/machines/');
      const loaded = res.data?.results ?? (Array.isArray(res.data) ? res.data : []);
      setMachines(loaded);
      if (loaded.length > 0 && !selectedMachine) {
        let initial = loaded[0];
        if (targetMachineId) {
          const match = loaded.find(m => String(m.id) === String(targetMachineId));
          if (match) initial = match;
        }
        setSelectedMachine(initial);
      }
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to load machines.'));
    }
  }, [selectedMachine, targetMachineId]);

  useEffect(() => {
    const init = async () => {
      setLoading(true);
      await loadMachines();
      setLoading(false);
    };
    init();
  }, []);

  // 2. Fetch Parts for Selected Machine strictly
  const loadPartsForMachine = useCallback(async () => {
    if (!selectedMachine) {
      setParts([]);
      setSelectedPart(null);
      return;
    }
    try {
      setError('');
      const res = await getParts(selectedMachine.id);
      const loaded = res.data?.results ?? (Array.isArray(res.data) ? res.data : []);
      setParts(loaded);
      if (loaded.length > 0) {
        let initial = loaded[0];
        if (targetPartId) {
          const match = loaded.find(p => String(p.id) === String(targetPartId) || p.part_number === targetPartId);
          if (match) initial = match;
        }
        setSelectedPart(initial);
      } else {
        setSelectedPart(null);
      }
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to load parts for selected machine.'));
    }
  }, [selectedMachine, targetPartId]);

  useEffect(() => {
    loadPartsForMachine();
  }, [loadPartsForMachine]);

  // 3. Fetch Operations (Templates) for Selected Part strictly
  const loadTemplates = useCallback(async () => {
    if (!selectedPart) {
      setTemplates([]);
      setSelectedTemplate(null);
      setParameters([]);
      return;
    }
    try {
      setError('');
      const res = await getPartTemplates(selectedPart.part_number);
      const loaded = res.data?.results ?? (Array.isArray(res.data) ? res.data : []);
      setTemplates(loaded);
      if (loaded.length > 0) {
        setSelectedTemplate(prev => {
          if (targetOpId) {
            const match = loaded.find(t => String(t.id) === String(targetOpId));
            if (match) return match;
          }
          if (prev) {
            const found = loaded.find(t => t.id === prev.id);
            if (found) return found;
          }
          return loaded[0];
        });
      } else {
        setSelectedTemplate(null);
        setParameters([]);
      }
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to load operations for selected part.'));
    }
  }, [selectedPart, targetOpId]);

  useEffect(() => {
    loadTemplates();
  }, [loadTemplates]);

  // 4. Fetch Product & Process Parameters for Selected Operation (Template) strictly
  const [processParameters, setProcessParameters] = useState([]);
  const [showProcessParamModal, setShowProcessParamModal] = useState(false);
  const [editingProcessParam, setEditingProcessParam] = useState(null);
  const [processRuleMode, setProcessRuleMode] = useState('rule1'); // 'rule1', 'rule2', 'rule3'
  const [processParamForm, setProcessParamForm] = useState({
    parameter_code: '',
    parameter_name: '',
    nominal_value: '10.00',
    upper_tolerance: '0.10',
    lower_tolerance: '-0.10',
    unit: 'mm',
    data_type: 'numeric',
    measurement_type: 'dimensional',
    specification: '',
    is_required: true,
    is_active: true,
    sequence_order: 1,
    measurement_technique: 'VERNIER CALIPER',
    sample_size: '5NOS/SHIFT',
    control_method: '1st PIECE & INPROCESS INSP.',
  });

  const loadParameters = useCallback(async () => {
    if (!selectedTemplate) {
      setParameters([]);
      setProcessParameters([]);
      return;
    }
    try {
      setError('');
      const [resProd, resProc] = await Promise.all([
        getTemplateParameters(selectedTemplate.id),
        getProcessParameters(selectedTemplate.id),
      ]);
      const loadedProd = resProd.data?.results ?? (Array.isArray(resProd.data) ? resProd.data : []);
      const loadedProc = resProc.data?.results ?? (Array.isArray(resProc.data) ? resProc.data : []);
      setParameters(loadedProd);
      setProcessParameters(loadedProc);
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to load parameters for operation.'));
    }
  }, [selectedTemplate]);

  useEffect(() => {
    loadParameters();
  }, [loadParameters]);

  // MACHINE HANDLERS
  const handleOpenAddMachine = () => {
    if (!requireManageAccess('add a machine')) return;
    setEditingMachine(null);
    setMachineForm({ machine_code: '', name: '', machine_type: 'CNC' });
    setShowAddMachineModal(true);
  };

  const handleOpenEditMachine = (m) => {
    if (!requireManageAccess('edit a machine')) return;
    setEditingMachine(m);
    setMachineForm({ machine_code: m.machine_code, name: m.name || '', machine_type: m.machine_type || 'CNC' });
    setShowAddMachineModal(true);
  };

  const handleSaveMachine = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('save machine changes')) return;
    if (!machineForm.machine_code.trim()) return;
    try {
      setError('');
      setSuccessMsg('');
      if (editingMachine) {
        const res = await api.put(`/api/machines/${editingMachine.id}/`, {
          machine_code: machineForm.machine_code.trim().toUpperCase(),
          name: machineForm.name.trim() || `Machine ${machineForm.machine_code.trim()}`,
          machine_type: machineForm.machine_type,
          status: 'active',
        });
        setSuccessMsg(`Machine ${res.data.machine_code} updated!`);
        setSelectedMachine(res.data);
      } else {
        const res = await api.post('/api/machines/', {
          machine_code: machineForm.machine_code.trim().toUpperCase(),
          name: machineForm.name.trim() || `Machine ${machineForm.machine_code.trim()}`,
          machine_type: machineForm.machine_type,
          status: 'active',
        });
        setSuccessMsg(`Machine ${res.data.machine_code} created!`);
        setSelectedMachine(res.data);
      }
      setShowAddMachineModal(false);
      await loadMachines();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to save machine.'));
    }
  };

  const handleDeleteMachine = async (mId) => {
    if (!requireManageAccess('delete a machine')) return;
    if (!window.confirm('Are you sure you want to delete this Machine and all associated Parts?')) return;
    try {
      setError('');
      await api.delete(`/api/machines/${mId}/`);
      setSuccessMsg('Machine deleted.');
      setSelectedMachine(null);
      await loadMachines();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to delete machine.'));
    }
  };

  // PART HANDLERS
  const handleOpenAddPart = () => {
    if (!requireManageAccess('add a part')) return;
    if (!selectedMachine) {
      setError('Please select or create a machine first.');
      return;
    }
    setEditingPart(null);
    setPartForm({ part_number: '', part_name: '', drawing_number: '', revision: 'A', description: '' });
    setShowAddPartModal(true);
  };

  const handleOpenEditPart = (p) => {
    if (!requireManageAccess('edit a part')) return;
    setEditingPart(p);
    setPartForm({
      part_number: p.part_number,
      part_name: p.part_name,
      drawing_number: p.drawing_number || '',
      revision: p.revision || 'A',
      description: p.description || '',
    });
    setShowAddPartModal(true);
  };

  const handleSavePart = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('save part changes')) return;
    if (!selectedMachine) return;
    try {
      setError('');
      setSuccessMsg('');
      const cleanPartNum = partForm.part_number.trim().replace(/[\/#]+$/, '');
      const payload = { ...partForm, part_number: cleanPartNum, machine: selectedMachine.id };
      if (editingPart) {
        const res = await updatePart(editingPart.part_number, payload);
        setSuccessMsg(`Part ${res.data.part_number} updated!`);
        setSelectedPart(res.data);
      } else {
        const res = await createPart(payload);
        setSuccessMsg(`Part ${res.data.part_number} created for machine ${selectedMachine.machine_code}!`);
        setSelectedPart(res.data);
      }
      setShowAddPartModal(false);
      await loadPartsForMachine();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to save part.'));
    }
  };

  const handleDeletePartItem = async (partNum) => {
    if (!requireManageAccess('delete a part')) return;
    if (!window.confirm(`Are you sure you want to delete Part ${partNum} and all its operations & parameters?`)) return;
    try {
      setError('');
      await deletePart(partNum);
      setSuccessMsg(`Part ${partNum} deleted.`);
      setSelectedPart(null);
      await loadPartsForMachine();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to delete part.'));
    }
  };

  // OPERATION HANDLERS
  const handleSaveOperation = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('save an operation')) return;
    if (!selectedPart) return;
    try {
      setError('');
      setSuccessMsg('');
      const targetCount = parseInt(newOpTargetCount) || 10;
      const opTitle = newOpName.trim() || `${newOpType.replace('_', ' ').toUpperCase()} Sheet`;
      const res = await createTemplate(selectedPart.part_number, {
        name: opTitle,
        inspection_type: newOpType,
        target_parameter_count: targetCount,
        cycle_time_mins: parseFloat(newOpCycleTime) || 0.0,
        is_active: true
      });
      setSuccessMsg(`Operation "${opTitle}" created with target of ${targetCount} parameters!`);
      setShowAddOpModal(false);
      setNewOpName('');
      setNewOpCycleTime('');
      await loadTemplates();
      if (res.data?.id) setSelectedTemplate(res.data);
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to add operation.'));
    }
  };

  const handleSaveTargetCount = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('edit target settings')) return;
    if (!selectedTemplate) return;
    try {
      setError('');
      setSuccessMsg('');
      const targetVal = parseInt(editTargetCount) || 10;
      const cycleVal = parseFloat(editCycleTime) || 0.0;
      const res = await updateTemplate(selectedTemplate.id, { 
        target_parameter_count: targetVal,
        cycle_time_mins: cycleVal
      });
      setSelectedTemplate(res.data);
      setSuccessMsg(`Target parameter count updated to ${targetVal} for this operation!`);
      setShowEditTargetModal(false);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to update target parameters count.'));
    }
  };

  const handlePublishTemplate = async () => {
    if (!requireManageAccess('publish an operation')) return;
    if (!selectedTemplate) return;
    setIsPublishing(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await publishTemplate(selectedTemplate.id);
      setSuccessMsg(res.data?.message || 'Operation published & dispatched to mobile apps successfully!');
      setSelectedTemplate((prev) => ({
        ...prev,
        is_published: true,
        published_at: res.data?.published_at || new Date().toISOString(),
      }));
      setShowPublishModal(false);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to publish template to mobile.'));
    } finally {
      setIsPublishing(false);
    }
  };

  // ─── Sign-Off Workflow Handlers ───────────────────────────────────────────
  const handleOpenSubmitReviewModal = () => {
    if (!requireManageAccess('submit an operation for review')) return;
    if (!selectedTemplate) return;
    setSubmitReviewForm({
      assigned_reviewer: selectedTemplate.assigned_reviewer || '',
      assigned_approver: selectedTemplate.assigned_approver || '',
      notes: '',
    });
    setShowSubmitReviewModal(true);
  };

  const handleSubmitReview = async (e) => {
    if (e) e.preventDefault();
    if (!requireManageAccess('submit an operation for review')) return;
    if (!selectedTemplate) return;
    setIsSubmittingReview(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await submitTemplateReview(selectedTemplate.id, {
        assigned_reviewer: submitReviewForm.assigned_reviewer || null,
        assigned_approver: submitReviewForm.assigned_approver || null,
        notes: submitReviewForm.notes,
      });
      setSuccessMsg(res.data?.message || 'Operation submitted for review successfully!');
      if (res.data?.template) {
        setSelectedTemplate(res.data.template);
      }
      setShowSubmitReviewModal(false);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to submit operation for review.'));
    } finally {
      setIsSubmittingReview(false);
    }
  };

  const handleOpenReviewModal = () => {
    if (!requireManageAccess('review an operation')) return;
    if (!selectedTemplate) return;
    setReviewActionForm({
      action: 'recommend',
      comments: '',
    });
    setShowReviewModal(true);
  };

  const handleSubmitReviewAction = async (chosenAction) => {
    if (!requireManageAccess('review an operation')) return;
    if (!selectedTemplate) return;
    const actionToUse = chosenAction || reviewActionForm.action;
    setIsProcessingReview(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await reviewTemplateAction(selectedTemplate.id, {
        action: actionToUse,
        comments: reviewActionForm.comments,
      });
      setSuccessMsg(res.data?.message || 'Review action recorded successfully!');
      if (res.data?.template) {
        setSelectedTemplate(res.data.template);
      }
      setShowReviewModal(false);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to record review action.'));
    } finally {
      setIsProcessingReview(false);
    }
  };

  const handleOpenApproveModal = () => {
    if (!requireManageAccess('approve an operation')) return;
    if (!selectedTemplate) return;
    setApproveActionForm({
      action: 'approve',
      comments: '',
    });
    setShowApproveModal(true);
  };

  const handleSubmitApproveAction = async (chosenAction) => {
    if (!requireManageAccess('approve an operation')) return;
    if (!selectedTemplate) return;
    const actionToUse = chosenAction || approveActionForm.action;
    setIsProcessingApprove(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await approveTemplateAction(selectedTemplate.id, {
        action: actionToUse,
        comments: approveActionForm.comments,
      });
      setSuccessMsg(res.data?.message || 'Approval action recorded successfully!');
      if (res.data?.template) {
        setSelectedTemplate(res.data.template);
      }
      setShowApproveModal(false);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to record approval action.'));
    } finally {
      setIsProcessingApprove(false);
    }
  };

  const handleDeleteOperationItem = async (templateId) => {
    if (!requireManageAccess('delete an operation')) return;
    if (!window.confirm('Are you sure you want to delete this Operation and all its parameters?')) return;
    try {
      setError('');
      await deleteTemplate(templateId);
      setSuccessMsg('Operation deleted.');
      setSelectedTemplate(null);
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to delete operation.'));
    }
  };

  // ── Metrics & Gating: All Parameters Filled Check ──
  const totalConfiguredParams = parameters.length + processParameters.length;
  const targetRequiredParams = selectedTemplate?.target_parameter_count || 10;
  const isAllParametersFilled = totalConfiguredParams >= targetRequiredParams && totalConfiguredParams > 0;
  const isApproved = selectedTemplate?.status === 'approved';

  const handleInitiateSubmitReview = () => {
    if (!requireManageAccess('submit an operation for review')) return;
    if (!selectedTemplate) return;
    if (totalConfiguredParams === 0) {
      setError('Please add at least one Product or Process parameter before submitting for Quality Sign-Off.');
      return;
    }
    handleOpenSubmitReviewModal();
  };

  // ── Locked State Interception for Approved Templates (DCR Workflow) ──
  const handleOpenGeneralDCRModal = () => {
    if (!requireManageAccess('create a change request')) return;
    setDcrForm({
      change_type: 'modification',
      target_type: activeParamTab,
      target_param_id: '',
      parameter_code: '',
      parameter_name: '',
      current_specification: '',
      proposed_specification: '',
      basis_for_change: '',
      assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
      assigned_approver: selectedTemplate?.assigned_approver || '',
    });
    setShowDCRModal(true);
  };

  const handleOpenAddParamWithLockCheck = () => {
    if (!requireManageAccess('add a product parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'addition',
        target_type: 'product',
        target_param_id: '',
        parameter_code: `P${parameters.length + 1}`,
        parameter_name: '',
        current_specification: 'New Product Parameter Addition',
        proposed_specification: '',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleOpenAddParam();
  };

  const handleOpenAddProcessParamWithLockCheck = () => {
    if (!requireManageAccess('add a process parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'addition',
        target_type: 'process',
        target_param_id: '',
        parameter_code: `PR${processParameters.length + 1}`,
        parameter_name: '',
        current_specification: 'New Process Parameter Addition',
        proposed_specification: '',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleOpenAddProcessParam();
  };

  const handleEditParamWithLockCheck = (p) => {
    if (!requireManageAccess('edit a product parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'modification',
        target_type: 'product',
        target_param_id: p.id,
        parameter_code: p.parameter_code || `P${p.sequence_order}`,
        parameter_name: p.parameter_name,
        current_specification: `Nominal: ${p.nominal_value} ${p.unit}, Tol: +${p.upper_tolerance} / ${p.lower_tolerance} (${p.measurement_type})`,
        proposed_specification: '',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleOpenEditParam(p);
  };

  const handleDeleteParamWithLockCheck = (p) => {
    if (!requireManageAccess('delete a product parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'deletion',
        target_type: 'product',
        target_param_id: p.id,
        parameter_code: p.parameter_code || `P${p.sequence_order}`,
        parameter_name: p.parameter_name,
        current_specification: `Nominal: ${p.nominal_value} ${p.unit}, Tol: +${p.upper_tolerance} / ${p.lower_tolerance} (${p.measurement_type})`,
        proposed_specification: 'Deactivation / Deletion of Parameter',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleDeleteParam(p.id);
  };

  const handleEditProcessParamWithLockCheck = (pp) => {
    if (!requireManageAccess('edit a process parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'modification',
        target_type: 'process',
        target_param_id: pp.id,
        parameter_code: pp.parameter_code || `PR${pp.sequence_order}`,
        parameter_name: pp.parameter_name,
        current_specification: pp.specification || `Nominal: ${pp.nominal_value} ${pp.unit}, Tol: +${pp.upper_tolerance} / ${pp.lower_tolerance}`,
        proposed_specification: '',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleOpenEditProcessParam(pp);
  };

  const handleDeleteProcessParamWithLockCheck = (pp) => {
    if (!requireManageAccess('delete a process parameter')) return;
    if (isApproved) {
      setDcrForm({
        change_type: 'deletion',
        target_type: 'process',
        target_param_id: pp.id,
        parameter_code: pp.parameter_code || `PR${pp.sequence_order}`,
        parameter_name: pp.parameter_name,
        current_specification: pp.specification || `Nominal: ${pp.nominal_value} ${pp.unit}, Tol: +${pp.upper_tolerance} / ${pp.lower_tolerance}`,
        proposed_specification: 'Deactivation / Deletion of Process Parameter',
        basis_for_change: '',
        assigned_reviewer: selectedTemplate?.assigned_reviewer || '',
        assigned_approver: selectedTemplate?.assigned_approver || '',
      });
      setShowDCRModal(true);
      return;
    }
    handleDeleteProcessParam(pp);
  };

  // ── DCR Submission, Review & Approval Actions ──
  const handleSubmitDCR = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('submit a change request')) return;
    if (!selectedTemplate) return;
    setIsSubmittingDCR(true);
    try {
      setError('');
      setSuccessMsg('');
      const payload = {
        change_type: dcrForm.change_type,
        is_process_parameter: dcrForm.target_type === 'process',
        parameter: (dcrForm.target_type === 'product' && dcrForm.target_param_id) ? dcrForm.target_param_id : null,
        process_parameter: (dcrForm.target_type === 'process' && dcrForm.target_param_id) ? dcrForm.target_param_id : null,
        parameter_code: dcrForm.parameter_code,
        parameter_name: dcrForm.parameter_name,
        current_specification: dcrForm.current_specification,
        proposed_specification: dcrForm.proposed_specification,
        basis_for_change: dcrForm.basis_for_change,
        assigned_reviewer: dcrForm.assigned_reviewer || null,
        assigned_approver: dcrForm.assigned_approver || null,
      };
      const res = await submitTemplateDCR(selectedTemplate.id, payload);
      setSuccessMsg(`Document Change Request ${res.data?.dcr_number || ''} submitted successfully!`);
      setShowDCRModal(false);
      await loadTemplateDCRs();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to submit Document Change Request.'));
    } finally {
      setIsSubmittingDCR(false);
    }
  };

  const handleOpenDCRReviewModal = (dcr) => {
    if (!requireManageAccess('review a change request')) return;
    setSelectedDCR(dcr);
    setDcrReviewForm({
      action: 'recommend',
      remarks: '',
    });
    setShowDCRReviewModal(true);
  };

  const handleReviewDCRSubmit = async (chosenAction) => {
    if (!requireManageAccess('review a change request')) return;
    if (!selectedDCR) return;
    const action = chosenAction || dcrReviewForm.action;
    setIsProcessingDCRReview(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await reviewTemplateDCR(selectedDCR.id, {
        action,
        remarks: dcrReviewForm.remarks,
      });
      setSuccessMsg(res.data?.message || 'DCR reviewed successfully!');
      setShowDCRReviewModal(false);
      await loadTemplateDCRs();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to review DCR.'));
    } finally {
      setIsProcessingDCRReview(false);
    }
  };

  const handleOpenDCRApproveModal = (dcr) => {
    if (!requireManageAccess('approve a change request')) return;
    setSelectedDCR(dcr);
    setDcrApproveForm({
      action: 'approve',
      remarks: '',
    });
    setShowDCRApproveModal(true);
  };

  const handleApproveDCRSubmit = async (chosenAction) => {
    if (!requireManageAccess('approve a change request')) return;
    if (!selectedDCR) return;
    const action = chosenAction || dcrApproveForm.action;
    setIsProcessingDCRApprove(true);
    try {
      setError('');
      setSuccessMsg('');
      const res = await approveTemplateDCR(selectedDCR.id, {
        action,
        remarks: dcrApproveForm.remarks,
      });
      setSuccessMsg(res.data?.message || 'DCR approved and parameter specification updated!');
      setShowDCRApproveModal(false);
      await loadTemplateDCRs();
      await loadParameters();
      await loadTemplates();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to approve DCR.'));
    } finally {
      setIsProcessingDCRApprove(false);
    }
  };

  const selectRuleMode = (mode) => {
    setRuleMode(mode);
    if (mode === 'rule2') {
      setParamForm(prev => ({
        ...prev,
        measurement_type: 'visual',
        unit: 'Pass',
        nominal_value: '1.00',
        upper_tolerance: '0.00',
        lower_tolerance: '0.00',
      }));
    } else if (mode === 'rule3') {
      setParamForm(prev => ({
        ...prev,
        measurement_type: 'max_limit',
        unit: prev.unit === 'Pass' ? 'mm' : prev.unit,
        nominal_value: prev.nominal_value || '1.60',
        upper_tolerance: '0.00',
        lower_tolerance: '0.00',
      }));
    } else {
      setParamForm(prev => ({
        ...prev,
        measurement_type: 'dimensional',
        unit: prev.unit === 'Pass' ? 'mm' : prev.unit,
        nominal_value: prev.nominal_value || '10.00',
        upper_tolerance: '0.10',
        lower_tolerance: '-0.10',
      }));
    }
  };

  const handleOpenAddParam = () => {
    if (!requireManageAccess('add a product parameter')) return;
    setEditingParam(null);
    setRuleMode('rule1');
    setParamForm({
      parameter_code: `P${parameters.length + 1}`,
      parameter_name: '',
      nominal_value: '10.00',
      upper_tolerance: '0.10',
      lower_tolerance: '-0.10',
      unit: 'mm',
      measurement_type: 'dimensional',
      is_critical: false,
      sequence_order: parameters.length + 1,
      measurement_technique: 'VERNIER CALIPER',
      sample_size: '5NOS/SHIFT',
      control_method: '1st PIECE & INPROCESS INSP.',
      voice_prompt: '',
    });
    setShowAddParamModal(true);
  };

  const handleOpenEditParam = (param) => {
    if (!requireManageAccess('edit a product parameter')) return;
    setEditingParam(param);
    let mode = 'rule1';
    const mType = (param.measurement_type || '').toLowerCase();
    if (mType === 'visual') mode = 'rule2';
    else if (['surface', 'min_limit', 'max_limit'].includes(mType)) mode = 'rule3';
    setRuleMode(mode);

    setParamForm({
      parameter_code: param.parameter_code,
      parameter_name: param.parameter_name,
      nominal_value: param.nominal_value,
      upper_tolerance: param.upper_tolerance,
      lower_tolerance: param.lower_tolerance,
      unit: param.unit,
      measurement_type: param.measurement_type,
      is_critical: param.is_critical,
      sequence_order: param.sequence_order,
      measurement_technique: param.measurement_technique || '',
      sample_size: param.sample_size || '',
      control_method: param.control_method || '',
      voice_prompt: param.voice_prompt || '',
    });
    setShowAddParamModal(true);
  };

  const handleSaveParam = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('save product parameter changes')) return;
    if (!selectedTemplate) return;
    try {
      setError('');
      setSuccessMsg('');
      const nominal = parseFloat(paramForm.nominal_value) || 0;
      const upperT = Math.abs(parseFloat(paramForm.upper_tolerance) || 0);
      const rawLower = parseFloat(paramForm.lower_tolerance) || 0;
      const lowerT = rawLower > 0 ? -rawLower : rawLower;

      const seqOrder = editingParam ? (editingParam.sequence_order || 1) : (parameters.length + 1);
      const autoCode = `P${seqOrder}`;

      const payload = {
        ...paramForm,
        parameter_code: autoCode,
        sequence_order: seqOrder,
        nominal_value: nominal,
        upper_tolerance: upperT,
        lower_tolerance: lowerT,
      };

      if (editingParam) {
        await updateParameter(editingParam.id, payload);
        setSuccessMsg(`Parameter #${seqOrder} updated!`);
      } else {
        await createParameter(selectedTemplate.id, payload);
        setSuccessMsg(`Parameter #${seqOrder} added sequentially!`);
      }
      setShowAddParamModal(false);
      loadParameters();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to save parameter.'));
    }
  };

  const handleDeleteParam = async (paramId) => {
    if (!requireManageAccess('delete a product parameter')) return;
    if (!window.confirm('Are you sure you want to delete this parameter?')) return;
    try {
      setError('');
      await deleteParameter(paramId);
      setSuccessMsg('Parameter deleted.');
      await loadParameters();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to delete parameter.'));
    }
  };

  const selectProcessRuleMode = (mode) => {
    setProcessRuleMode(mode);
    if (mode === 'rule2') {
      setProcessParamForm(prev => ({
        ...prev,
        measurement_type: 'visual',
        unit: 'Pass',
        nominal_value: '1.00',
        upper_tolerance: '0.00',
        lower_tolerance: '0.00',
      }));
    } else if (mode === 'rule3') {
      setProcessParamForm(prev => ({
        ...prev,
        measurement_type: 'max_limit',
        unit: prev.unit === 'Pass' ? 'mm' : prev.unit,
        nominal_value: prev.nominal_value || '1.60',
        upper_tolerance: '0.00',
        lower_tolerance: '0.00',
      }));
    } else {
      setProcessParamForm(prev => ({
        ...prev,
        measurement_type: 'dimensional',
        unit: prev.unit === 'Pass' ? 'mm' : prev.unit,
        nominal_value: prev.nominal_value || '10.00',
        upper_tolerance: '0.10',
        lower_tolerance: '-0.10',
      }));
    }
  };

  const handleOpenAddProcessParam = () => {
    if (!requireManageAccess('add a process parameter')) return;
    setEditingProcessParam(null);
    setProcessRuleMode('rule1');
    setProcessParamForm({
      parameter_code: `PR${processParameters.length + 1}`,
      parameter_name: '',
      nominal_value: '10.00',
      upper_tolerance: '0.10',
      lower_tolerance: '-0.10',
      unit: 'mm',
      data_type: 'numeric',
      measurement_type: 'dimensional',
      specification: '',
      is_required: true,
      is_active: true,
      sequence_order: processParameters.length + 1,
      measurement_technique: 'VERNIER CALIPER',
      sample_size: '5NOS/SHIFT',
      control_method: '1st PIECE & INPROCESS INSP.',
    });
    setShowProcessParamModal(true);
  };

  const handleOpenEditProcessParam = (pp) => {
    if (!requireManageAccess('edit a process parameter')) return;
    setEditingProcessParam(pp);
    let mode = 'rule1';
    const mType = (pp.measurement_type || '').toLowerCase();
    if (mType === 'visual') mode = 'rule2';
    else if (['surface', 'min_limit', 'max_limit'].includes(mType)) mode = 'rule3';
    setProcessRuleMode(mode);

    setProcessParamForm({
      parameter_code: pp.parameter_code || '',
      parameter_name: pp.parameter_name || '',
      data_type: pp.data_type || 'numeric',
      nominal_value: pp.nominal_value ?? '10.00',
      upper_tolerance: pp.upper_tolerance ?? '0.10',
      lower_tolerance: pp.lower_tolerance ?? '-0.10',
      unit: pp.unit || 'mm',
      measurement_type: pp.measurement_type || 'dimensional',
      specification: pp.specification || '',
      is_required: pp.is_required !== false,
      is_active: pp.is_active !== false,
      sequence_order: pp.sequence_order || 1,
      measurement_technique: pp.measurement_technique || '',
      sample_size: pp.sample_size || '',
      control_method: pp.control_method || '',
    });
    setShowProcessParamModal(true);
  };

  const handleSaveProcessParam = async (e) => {
    e.preventDefault();
    if (!requireManageAccess('save process parameter changes')) return;
    if (!selectedTemplate || !processParamForm.parameter_name.trim()) return;
    try {
      setError('');
      setSuccessMsg('');
      const nominal = parseFloat(processParamForm.nominal_value) || 0;
      const upperT = Math.abs(parseFloat(processParamForm.upper_tolerance) || 0);
      const rawLower = parseFloat(processParamForm.lower_tolerance) || 0;
      const lowerT = rawLower > 0 ? -rawLower : rawLower;

      const seqOrder = editingProcessParam ? (editingProcessParam.sequence_order || 1) : (processParameters.length + 1);

      const payload = {
        template: selectedTemplate.id,
        parameter_name: processParamForm.parameter_name.trim(),
        parameter_code: processParamForm.parameter_code.trim() || `PR${seqOrder}`,
        data_type: processParamForm.data_type,
        measurement_type: processParamForm.measurement_type || 'dimensional',
        unit: processParamForm.unit.trim(),
        specification: processParamForm.specification.trim(),
        nominal_value: nominal,
        upper_tolerance: upperT,
        lower_tolerance: lowerT,
        is_required: processParamForm.is_required,
        is_active: processParamForm.is_active,
        sequence_order: seqOrder,
        measurement_technique: processParamForm.measurement_technique || '',
        sample_size: processParamForm.sample_size || '',
        control_method: processParamForm.control_method || '',
      };

      if (editingProcessParam) {
        await updateProcessParameter(editingProcessParam.id, payload);
        setSuccessMsg(`Process Parameter "${payload.parameter_name}" updated!`);
      } else {
        await createProcessParameter(selectedTemplate.id, payload);
        setSuccessMsg(`Process Parameter "${payload.parameter_name}" created!`);
      }
      setShowProcessParamModal(false);
      await loadParameters();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to save process parameter.'));
    }
  };

  const handleDeleteProcessParam = async (pp) => {
    if (!requireManageAccess('delete a process parameter')) return;
    if (!window.confirm(`Delete process parameter "${pp.parameter_name}"?`)) return;
    try {
      setError('');
      setSuccessMsg('');
      await deleteProcessParameter(pp.id);
      setSuccessMsg(`Process Parameter "${pp.parameter_name}" deleted.`);
      await loadParameters();
    } catch (err) {
      setError(extractErrorMessage(err, 'Failed to delete process parameter.'));
    }
  };

  if (loading) return <LoadingSpinner message="Loading Master Database..." />;

  const nom = parseFloat(paramForm.nominal_value) || 0;
  const upperT = parseFloat(paramForm.upper_tolerance) || 0;
  const lowerT = parseFloat(paramForm.lower_tolerance) || 0;

  return (
    <>
      <Header
        title="Master Database Builder"
        subtitle={isAdmin 
          ? "Factory Master Parameters & Inspection Matrix: Machine → Part → Operation → Parameters"
          : "Supervisor Manual Configuration: Machine → Part → Operation → Parameters (P1, P2...)"
        }
      />

      <div className="page-content" style={{ padding: '24px', background: '#F8FAFC', minHeight: '100vh' }}>
        <Breadcrumbs items={[{ label: 'Master Database', to: '/master-database' }, { label: 'Master Parameters' }]} />

        {/* ── TOP PAGE HEADER BAR ─────────────────────────────── */}
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          background: '#FFFFFF',
          border: '1px solid #E2E8F0',
          borderRadius: 14, padding: '16px 24px', marginBottom: 20,
          boxShadow: '0 2px 8px rgba(0,0,0,0.04)',
          flexWrap: 'wrap', gap: 12
        }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 800, color: '#0F172A', letterSpacing: '-0.3px' }}>
              Factory Master Registry
            </div>
            <div style={{ fontSize: 12, color: '#64748B', marginTop: 2 }}>
              Master Database & Inspection Parameters Configuration
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            {isAdmin && (
              <div style={{ display: 'flex', background: '#F1F5F9', padding: '4px', borderRadius: '10px', border: '1px solid #E2E8F0' }}>
                <button
                  type="button"
                  onClick={() => setAdminTab('builder')}
                  style={{
                    padding: '6px 14px',
                    borderRadius: '8px',
                    border: 'none',
                    fontSize: '12px',
                    fontWeight: 700,
                    cursor: 'pointer',
                    background: adminTab === 'builder' ? '#FFFFFF' : 'transparent',
                    color: adminTab === 'builder' ? '#2563EB' : '#64748B',
                    boxShadow: adminTab === 'builder' ? '0 1px 3px rgba(0,0,0,0.1)' : 'none',
                    transition: 'all 0.15s ease'
                  }}
                >
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><Sliders size={13} /> Parameter Builder</span>
                </button>
                <button
                  type="button"
                  onClick={() => setAdminTab('audit')}
                  style={{
                    padding: '6px 14px',
                    borderRadius: '8px',
                    border: 'none',
                    fontSize: '12px',
                    fontWeight: 700,
                    cursor: 'pointer',
                    background: adminTab === 'audit' ? '#FFFFFF' : 'transparent',
                    color: adminTab === 'audit' ? '#2563EB' : '#64748B',
                    boxShadow: adminTab === 'audit' ? '0 1px 3px rgba(0,0,0,0.1)' : 'none',
                    transition: 'all 0.15s ease'
                  }}
                >
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><FileSpreadsheet size={13} /> Global Audit List</span>
                </button>
              </div>
            )}
            <span style={{
              background: isAdmin ? '#EFF6FF' : '#F0FDF4',
              border: `1px solid ${isAdmin ? '#BFDBFE' : '#BBF7D0'}`,
              color: isAdmin ? '#1D4ED8' : '#15803D',
              fontSize: 11, fontWeight: 700, padding: '5px 14px',
              borderRadius: 20, letterSpacing: '0.5px', textTransform: 'uppercase'
            }}>
              {isAdmin ? 'Admin Master Control' : 'Supervisor Access'}
            </span>
          </div>
        </div>

        {/* ── ALERTS ──────────────────────────────────────────── */}
        {error && (
          <div style={{
            background: '#FEF2F2', border: '1px solid #FECACA',
            color: '#B91C1C', padding: '12px 16px', borderRadius: 10, marginBottom: 16,
            display: 'flex', justifyContent: 'space-between', alignItems: 'center'
          }}>
            <span>{error}</span>
            <button style={{ background: 'none', border: 'none', color: '#B91C1C', cursor: 'pointer', fontSize: 18 }} onClick={() => setError('')}>×</button>
          </div>
        )}
        {successMsg && (
          <div style={{
            background: '#F0FDF4', border: '1px solid #BBF7D0',
            color: '#15803D', padding: '12px 16px', borderRadius: 10, marginBottom: 16,
            display: 'flex', justifyContent: 'space-between', alignItems: 'center'
          }}>
            <span>{successMsg}</span>
            <button style={{ background: 'none', border: 'none', color: '#15803D', cursor: 'pointer', fontSize: 18 }} onClick={() => setSuccessMsg('')}>×</button>
          </div>
        )}

        {isAdmin && adminTab === 'audit' ? (
          <AdminParametersView
            hideTopHeader={true}
            onSwitchToBuilder={() => setAdminTab('builder')}
          />
        ) : (
          <>
        {/* ── 1. CONFIGURATION (HIERARCHY SELECTORS) ───────────── */}
        <div style={{
          background: '#FFFFFF',
          border: '1px solid #E2E8F0', borderRadius: 14, padding: '20px 24px',
          marginBottom: 24, boxShadow: '0 2px 8px rgba(0,0,0,0.04)'
        }}>
          <div style={{ fontSize: 12, fontWeight: 800, color: '#0F172A', letterSpacing: '0.8px', textTransform: 'uppercase', marginBottom: 4 }}>
            CONFIGURATION HIERARCHY
          </div>
          <div style={{ fontSize: 12, color: '#64748B', marginBottom: 16 }}>
            Select Machine → Part → Operation to view and manage parameters.
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16 }}>

            {/* 1. MACHINE */}
            <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: '#334155', textTransform: 'uppercase', letterSpacing: '0.5px' }}>
                  1. Machine
                </div>
                <div style={{ display: 'flex', gap: 4 }}>
                  {selectedMachine && (
                    <>
                      <button style={{ padding: '2px 8px', fontSize: 11, background: '#FFFFFF', border: '1px solid #CBD5E1', borderRadius: 5, color: '#334155', cursor: 'pointer' }} onClick={() => handleOpenEditMachine(selectedMachine)}>Edit</button>
                      <button style={{ padding: '2px 8px', fontSize: 11, background: '#FFFFFF', border: '1px solid #FECACA', borderRadius: 5, color: '#DC2626', cursor: 'pointer' }} onClick={() => handleDeleteMachine(selectedMachine.id)}>Delete</button>
                    </>
                  )}
                  <button style={{ padding: '2px 8px', fontSize: 11, background: '#0F172A', border: '1px solid #0F172A', borderRadius: 5, color: '#FFFFFF', cursor: 'pointer', fontWeight: 600 }} onClick={handleOpenAddMachine}>+ New</button>
                </div>
              </div>
              <select
                style={{
                  width: '100%', background: '#FFFFFF', border: '1px solid #CBD5E1',
                  borderRadius: 6, padding: '8px 12px', color: '#0F172A',
                  fontSize: 13, fontWeight: 600, cursor: 'pointer', outline: 'none'
                }}
                value={selectedMachine?.id || ''}
                onChange={(e) => { const m = machines.find((mach) => mach.id === parseInt(e.target.value)); setSelectedMachine(m); }}
              >
                {machines.map((m) => (
                  <option key={m.id} value={m.id}>{m.machine_code} : {m.name}</option>
                ))}
              </select>
            </div>

            {/* 2. PART */}
            <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: '#334155', textTransform: 'uppercase', letterSpacing: '0.5px' }}>
                  2. Part {selectedMachine ? `(${selectedMachine.machine_code})` : ''}
                </div>
                <div style={{ display: 'flex', gap: 4 }}>
                  {selectedPart && (
                    <>
                      <button style={{ padding: '2px 8px', fontSize: 11, background: '#FFFFFF', border: '1px solid #CBD5E1', borderRadius: 5, color: '#334155', cursor: 'pointer' }} onClick={() => handleOpenEditPart(selectedPart)}>Edit</button>
                      <button style={{ padding: '2px 8px', fontSize: 11, background: '#FFFFFF', border: '1px solid #FECACA', borderRadius: 5, color: '#DC2626', cursor: 'pointer' }} onClick={() => handleDeletePartItem(selectedPart.part_number)}>Delete</button>
                    </>
                  )}
                  <button style={{ padding: '2px 8px', fontSize: 11, background: '#0F172A', border: '1px solid #0F172A', borderRadius: 5, color: '#FFFFFF', cursor: 'pointer', fontWeight: 600 }} onClick={handleOpenAddPart}>+ New</button>
                </div>
              </div>
              {parts.length > 0 ? (
                <select
                  style={{
                    width: '100%', background: '#FFFFFF', border: '1px solid #CBD5E1',
                    borderRadius: 6, padding: '8px 12px', color: '#0F172A',
                    fontSize: 13, fontWeight: 600, cursor: 'pointer', outline: 'none'
                  }}
                  value={selectedPart?.part_number || ''}
                  onChange={(e) => { const p = parts.find((pt) => pt.part_number === e.target.value); setSelectedPart(p); }}
                >
                  {parts.map((p) => (
                    <option key={p.id} value={p.part_number}>{p.part_number} : {p.part_name}</option>
                  ))}
                </select>
              ) : (
                <div style={{ fontSize: 12, color: '#D97706', paddingTop: 8 }}>No parts for this machine. Click "+ New".</div>
              )}
            </div>

            {/* 3. OPERATION */}
            <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: '#334155', textTransform: 'uppercase', letterSpacing: '0.5px' }}>
                  3. Operation {selectedPart ? `(${selectedPart.part_number})` : ''}
                </div>
                <div style={{ display: 'flex', gap: 4 }}>
                  {selectedTemplate && (
                    <button style={{ padding: '2px 8px', fontSize: 11, background: '#FFFFFF', border: '1px solid #FECACA', borderRadius: 5, color: '#DC2626', cursor: 'pointer' }} onClick={() => handleDeleteOperationItem(selectedTemplate.id)}>Delete</button>
                  )}
                  {selectedPart && (
                    <button style={{ padding: '2px 8px', fontSize: 11, background: '#0F172A', border: '1px solid #0F172A', borderRadius: 5, color: '#FFFFFF', cursor: 'pointer', fontWeight: 600 }} onClick={() => { if (requireManageAccess('add an operation')) setShowAddOpModal(true); }}>+ New</button>
                  )}
                </div>
              </div>
              {templates.length > 0 ? (
                <select
                  style={{
                    width: '100%', background: '#FFFFFF', border: '1px solid #CBD5E1',
                    borderRadius: 6, padding: '8px 12px', color: '#0F172A',
                    fontSize: 13, fontWeight: 600, cursor: 'pointer', outline: 'none'
                  }}
                  value={selectedTemplate?.id || ''}
                  onChange={(e) => { const t = templates.find((tmpl) => tmpl.id === parseInt(e.target.value)); setSelectedTemplate(t); }}
                >
                  {templates.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name ? t.name : t.inspection_type.toUpperCase()} (v{t.version}) [{t.status_display || (t.status ? t.status.toUpperCase() : 'DRAFT')}]
                    </option>
                  ))}
                </select>
              ) : (
                <div style={{ fontSize: 12, color: '#D97706', paddingTop: 8 }}>
                  {selectedPart ? 'No operations. Click "+ New"' : 'Select a Part first'}
                </div>
              )}
            </div>
          </div>
        </div>

        {/* ── 2. INSPECTION PARAMETERS SECTION ────────────────── */}
        <div style={{
          background: '#FFFFFF',
          border: '1px solid #E2E8F0', borderRadius: 14,
          boxShadow: '0 2px 12px rgba(0,0,0,0.06)', overflow: 'hidden',
          marginBottom: 24
        }}>

          {/* Section Header & Path Breadcrumb */}
          <div style={{
            display: 'flex', justifyContent: 'space-between', alignItems: 'center',
            flexWrap: 'wrap', gap: 14, padding: '18px 24px',
            borderBottom: '1px solid #F1F5F9', background: '#FAFBFC'
          }}>
            <div>
              <div style={{ fontSize: 16, fontWeight: 800, color: '#0F172A', letterSpacing: '-0.2px', marginBottom: 6 }}>
                Inspection Parameters
              </div>
              {selectedTemplate ? (
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{ fontSize: 13, fontWeight: 700, color: '#0F172A' }}>{selectedMachine?.machine_code}</span>
                  <span style={{ color: '#94A3B8', fontSize: 13 }}>/</span>
                  <span style={{ fontSize: 13, fontWeight: 700, color: '#0F172A' }}>{selectedPart?.part_number}</span>
                  <span style={{ color: '#94A3B8', fontSize: 13 }}>/</span>
                  <span style={{ fontSize: 13, fontWeight: 700, color: '#0F172A' }}>
                    {selectedTemplate?.name || selectedTemplate?.inspection_type.toUpperCase()}
                  </span>
                  <span style={{ fontSize: 12, color: '#64748B', fontWeight: 600 }}>
                    (v{selectedTemplate?.version})
                  </span>

                  {/* Clean Industrial Status Badge */}
                  <span style={{
                    padding: '3px 9px',
                    borderRadius: 6,
                    fontSize: 11,
                    fontWeight: 700,
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 6,
                    background:
                      selectedTemplate.status === 'approved' ? '#F0FDF4' :
                      selectedTemplate.status === 'reviewed' ? '#EFF6FF' :
                      selectedTemplate.status === 'under_review' ? '#FFFBEB' :
                      selectedTemplate.status === 'rejected' ? '#FEF2F2' : '#F8FAFC',
                    color:
                      selectedTemplate.status === 'approved' ? '#166534' :
                      selectedTemplate.status === 'reviewed' ? '#1E40AF' :
                      selectedTemplate.status === 'under_review' ? '#92400E' :
                      selectedTemplate.status === 'rejected' ? '#991B1B' : '#475569',
                    border: `1px solid ${
                      selectedTemplate.status === 'approved' ? '#BBF7D0' :
                      selectedTemplate.status === 'reviewed' ? '#BFDBFE' :
                      selectedTemplate.status === 'under_review' ? '#FDE68A' :
                      selectedTemplate.status === 'rejected' ? '#FECACA' : '#E2E8F0'
                    }`
                  }}>
                    <span style={{
                      width: 6,
                      height: 6,
                      borderRadius: '50%',
                      backgroundColor:
                        selectedTemplate.status === 'approved' ? '#16A34A' :
                        selectedTemplate.status === 'reviewed' ? '#2563EB' :
                        selectedTemplate.status === 'under_review' ? '#D97706' :
                        selectedTemplate.status === 'rejected' ? '#DC2626' : '#64748B'
                    }} />
                    {selectedTemplate.status === 'approved' ? 'Approved & Live' :
                     selectedTemplate.status === 'reviewed' ? 'Reviewed' :
                     selectedTemplate.status === 'under_review' ? `Under Review (${selectedTemplate.assigned_reviewer_name || 'Reviewer'})` :
                     selectedTemplate.status === 'rejected' ? 'Rejected' : 'Draft'}
                  </span>
                </div>
              ) : (
                <p style={{ margin: 0, fontSize: 13, color: '#94A3B8' }}>Select Machine / Part / Operation above to manage parameters.</p>
              )}
            </div>

            {/* Right Side: Action Toolbar & View Switcher */}
            {selectedTemplate && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                {/* View Mode Switcher */}
                {((activeParamTab === 'product' && parameters.length > 0) || (activeParamTab === 'process' && processParameters.length > 0)) && (
                  <div style={{ display: 'flex', background: '#F1F5F9', borderRadius: 8, padding: 3, border: '1px solid #CBD5E1', gap: 2 }}>
                    <button
                      onClick={() => setViewMode('blocks')}
                      style={{
                        padding: '5px 11px', fontSize: 12, fontWeight: 700, borderRadius: 6, border: 'none',
                        cursor: 'pointer', transition: 'all 0.15s',
                        background: viewMode === 'blocks' ? '#0F172A' : 'transparent',
                        color: viewMode === 'blocks' ? '#FFFFFF' : '#64748B',
                      }}
                    >Blocks</button>
                    <button
                      onClick={() => setViewMode('table')}
                      style={{
                        padding: '5px 11px', fontSize: 12, fontWeight: 700, borderRadius: 6, border: 'none',
                        cursor: 'pointer', transition: 'all 0.15s',
                        background: viewMode === 'table' ? '#0F172A' : 'transparent',
                        color: viewMode === 'table' ? '#FFFFFF' : '#64748B',
                      }}
                    >Table</button>
                  </div>
                )}

                {/* Add Parameter Button */}
                {activeParamTab === 'product' ? (
                  <button
                    type="button"
                    onClick={handleOpenAddParamWithLockCheck}
                    style={{
                      padding: '8px 14px', fontWeight: 600, borderRadius: 6, fontSize: 12.5,
                      background: '#0F172A',
                      border: '1px solid #0F172A', color: '#FFFFFF', cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex', alignItems: 'center', gap: 6,
                    }}
                  >
                    {isApproved ? <Lock size={13} /> : <Plus size={13} />}
                    <span>{isApproved ? 'Request Product Parameter (DCR)' : 'Add Product Parameter'}</span>
                  </button>
                ) : (
                  <button
                    type="button"
                    onClick={handleOpenAddProcessParamWithLockCheck}
                    style={{
                      padding: '8px 14px', fontWeight: 600, borderRadius: 6, fontSize: 12.5,
                      background: '#0F172A',
                      border: '1px solid #0F172A', color: '#FFFFFF', cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex', alignItems: 'center', gap: 6,
                    }}
                  >
                    {isApproved ? <Lock size={13} /> : <Plus size={13} />}
                    <span>{isApproved ? 'Request Process Parameter (DCR)' : 'Add Process Parameter'}</span>
                  </button>
                )}

                {/* Streamlined Submit Button for Draft / Initial / Rejected state */}
                {(!selectedTemplate.status || selectedTemplate.status === 'draft' || selectedTemplate.status === 'rejected') && (
                  <button
                    type="button"
                    onClick={handleInitiateSubmitReview}
                    title="Submit configured parameters for reviewer and approver sign-off"
                    style={{
                      padding: '8px 16px',
                      fontWeight: 600,
                      borderRadius: 6,
                      fontSize: 12.5,
                      background: '#2563EB',
                      border: '1px solid #1D4ED8',
                      color: '#FFFFFF',
                      cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 6,
                    }}
                  >
                    <Send size={13} />
                    <span>Submit</span>
                  </button>
                )}

                {/* Review & Recommend Button for Under Review state */}
                {(selectedTemplate.status === 'under_review' || (isAdmin && selectedTemplate.status !== 'approved')) && selectedTemplate.status !== 'reviewed' && (
                  <button
                    type="button"
                    onClick={handleOpenReviewModal}
                    title="Review parameter specifications and submit recommendation"
                    style={{
                      padding: '8px 16px',
                      fontWeight: 600,
                      borderRadius: 6,
                      fontSize: 12.5,
                      background: '#D97706',
                      border: '1px solid #B45309',
                      color: '#FFFFFF',
                      cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 6,
                    }}
                  >
                    <Eye size={13} />
                    <span>Review</span>
                  </button>
                )}

                {/* Final Approve Button for Reviewed state */}
                {(selectedTemplate.status === 'reviewed' || (isAdmin && selectedTemplate.status !== 'approved' && selectedTemplate.status !== 'draft')) && (
                  <button
                    type="button"
                    onClick={handleOpenApproveModal}
                    title="Final authorization and publish to mobile shop floor"
                    style={{
                      padding: '8px 16px',
                      fontWeight: 600,
                      borderRadius: 6,
                      fontSize: 12.5,
                      background: '#15803D',
                      border: '1px solid #166534',
                      color: '#FFFFFF',
                      cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 6,
                    }}
                  >
                    <CheckCircle2 size={13} />
                    <span>Approve</span>
                  </button>
                )}

                {/* Post-Approval DCR Button */}
                {selectedTemplate.status === 'approved' && (
                  <button
                    type="button"
                    onClick={handleOpenGeneralDCRModal}
                    title="Raise Document Change Request (Form DKI/MR/F/05) for locked parameters"
                    style={{
                      padding: '8px 14px',
                      fontWeight: 600,
                      borderRadius: 6,
                      fontSize: 12.5,
                      background: '#0F172A',
                      border: '1px solid #0F172A',
                      color: '#FFFFFF',
                      cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 6,
                    }}
                  >
                    <FileText size={13} />
                    <span>Initiate DCR</span>
                  </button>
                )}
              </div>
            )}
          </div>

          {/* Rejection Notice Banner (if rejected) */}
          {selectedTemplate?.status === 'rejected' && (
            <div style={{
              margin: '14px 24px 0 24px',
              background: '#FEF2F2',
              border: '1px solid #FCA5A5',
              borderRadius: 8,
              padding: '10px 16px',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              fontSize: 12.5,
              color: '#991B1B'
            }}>
              <AlertTriangle size={16} color="#DC2626" />
              <div>
                <strong>Revisions Requested:</strong> {selectedTemplate.rejection_reason || 'Please correct parameter ranges and re-submit.'}
              </div>
            </div>
          )}


          {/* TWO SEPARATED CATEGORY TABS (PRODUCT vs PROCESS ONLY) */}
          {selectedTemplate && (
            <div style={{
              display: 'flex', alignItems: 'center', padding: '10px 24px',
              background: '#F8FAFC', borderBottom: '1px solid #E2E8F0', gap: 8
            }}>
              <button
                type="button"
                onClick={() => setActiveParamTab('product')}
                style={{
                  padding: '7px 16px', borderRadius: 6, fontSize: 13, fontWeight: 600, cursor: 'pointer',
                  border: activeParamTab === 'product' ? '1px solid #0F172A' : '1px solid #CBD5E1',
                  background: activeParamTab === 'product' ? '#0F172A' : '#FFFFFF',
                  color: activeParamTab === 'product' ? '#FFFFFF' : '#475569',
                  boxShadow: activeParamTab === 'product' ? '0 1px 2px rgba(0,0,0,0.06)' : 'none',
                  display: 'flex', alignItems: 'center', gap: 8,
                }}
              >
                <Sliders size={14} />
                <span>Product Parameters</span>
                <span style={{
                  background: activeParamTab === 'product' ? '#334155' : '#F1F5F9',
                  color: activeParamTab === 'product' ? '#FFFFFF' : '#475569',
                  border: activeParamTab === 'product' ? 'none' : '1px solid #E2E8F0',
                  padding: '1px 7px', borderRadius: 10, fontSize: 11, fontWeight: 700
                }}>
                  {parameters.length}
                </span>
              </button>

              <button
                type="button"
                onClick={() => setActiveParamTab('process')}
                style={{
                  padding: '7px 16px', borderRadius: 6, fontSize: 13, fontWeight: 600, cursor: 'pointer',
                  border: activeParamTab === 'process' ? '1px solid #0F172A' : '1px solid #CBD5E1',
                  background: activeParamTab === 'process' ? '#0F172A' : '#FFFFFF',
                  color: activeParamTab === 'process' ? '#FFFFFF' : '#475569',
                  boxShadow: activeParamTab === 'process' ? '0 1px 2px rgba(0,0,0,0.06)' : 'none',
                  display: 'flex', alignItems: 'center', gap: 8,
                }}
              >
                <Settings size={14} />
                <span>Process Parameters</span>
                <span style={{
                  background: activeParamTab === 'process' ? '#334155' : '#F1F5F9',
                  color: activeParamTab === 'process' ? '#FFFFFF' : '#475569',
                  border: activeParamTab === 'process' ? 'none' : '1px solid #E2E8F0',
                  padding: '1px 7px', borderRadius: 10, fontSize: 11, fontWeight: 700
                }}>
                  {processParameters.length}
                </span>
              </button>

              <div style={{ flex: 1 }}></div>

              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: '#475569', background: '#FFFFFF', padding: '5px 12px', borderRadius: 6, border: '1px solid #E2E8F0' }}>
                  Cycle Time: <span style={{ color: '#0F172A', fontWeight: 800 }}>{selectedTemplate?.cycle_time_mins || 0} mins</span>
                </span>
                <button
                  type="button"
                  onClick={() => { 
                    if (!requireManageAccess('edit target settings')) return; 
                    setEditTargetCount(selectedTemplate?.target_parameter_count || 10); 
                    setEditCycleTime(selectedTemplate?.cycle_time_mins || ''); 
                    setShowEditTargetModal(true); 
                  }}
                  style={{
                    padding: '6px 14px', fontSize: 12, fontWeight: 700,
                    background: '#EFF6FF', border: '1px solid #BAE6FD',
                    borderRadius: 6, color: '#0284C7', cursor: 'pointer',
                    display: 'flex', alignItems: 'center', gap: 6, boxShadow: '0 1px 2px rgba(0,0,0,0.05)'
                  }}
                >
                  <Settings size={14} />
                  Operation Settings
                </button>
              </div>
            </div>
          )}

          {/* Governance Locked Notice for Approved Templates */}
          {selectedTemplate && isApproved && (
            <div style={{
              background: '#F8FAFC',
              borderBottom: '1px solid #E2E8F0',
              borderLeft: '4px solid #0F172A',
              padding: '12px 24px',
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              flexWrap: 'wrap',
              gap: 12
            }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <Lock size={16} color="#0F172A" />
                <div>
                  <div style={{ fontSize: 12.5, fontWeight: 700, color: '#0F172A' }}>
                    Specification Sheet Locked: Formal Quality Control (Form DKI/MR/F/05)
                  </div>
                  <div style={{ fontSize: 11.5, color: '#64748B', marginTop: 1 }}>
                    This operation template has undergone final sign-off. Direct parameter edits are disabled. All modifications, additions, and deletions are routed via Document Change Requests.
                  </div>
                </div>
              </div>
              <button
                type="button"
                onClick={handleOpenGeneralDCRModal}
                style={{
                  padding: '6px 14px',
                  borderRadius: 6,
                  fontSize: 12,
                  fontWeight: 600,
                  background: '#0F172A',
                  color: '#FFFFFF',
                  border: 'none',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: 6,
                  whiteSpace: 'nowrap'
                }}
              >
                <FileText size={13} />
                <span>Initiate DCR</span>
              </button>
            </div>
          )}

          {/* PARAMETER CONTENT BODY */}
          {!selectedTemplate ? (
            <div style={{ padding: '60px 40px', textAlign: 'center' }}>
              <div style={{ fontSize: 16, fontWeight: 700, color: '#64748B', marginBottom: 4 }}>No Operation Selected</div>
              <div style={{ fontSize: 13, color: '#94A3B8' }}>Select Machine → Part → Operation in the Configuration section above.</div>
            </div>
          ) : activeParamTab === 'product' ? (
            /* ── A. PRODUCT PARAMETERS SECTION ──────────────────────── */
            <div>
              <div style={{ padding: '14px 24px', background: '#F1F5F9', borderBottom: '1px solid #E2E8F0', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 800, color: '#0F172A', textTransform: 'uppercase', letterSpacing: '0.5px' }}>
                    PRODUCT PARAMETERS ({parameters.length})
                  </div>
                  <div style={{ fontSize: 12, color: '#64748B', marginTop: 2 }}>
                    Quality characteristics and product checks (Measurable dimensions & visual specs used for Hourly & Setup Inspections)
                  </div>
                </div>
              </div>

              {parameters.length === 0 ? (
                <div style={{ padding: '50px 40px', textAlign: 'center' }}>
                  <div style={{ fontSize: 15, fontWeight: 700, color: '#1E293B', marginBottom: 4 }}>No Product Parameters Configured</div>
                  <div style={{ fontSize: 12, color: '#64748B', marginBottom: 16 }}>
                    Click "+ Add Product Parameter" in the header toolbar above or below to define quality inspection rules.
                  </div>
                  <button
                    type="button"
                    onClick={handleOpenAddParamWithLockCheck}
                    style={{
                      padding: '9px 18px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                      background: '#0F172A',
                      border: '1px solid #0F172A', color: '#FFFFFF', cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'inline-flex', alignItems: 'center', gap: 6,
                    }}
                  >
                    {isApproved ? <Lock size={14} /> : <Plus size={14} />}
                    <span>{isApproved ? 'Request Product Parameter (DCR)' : 'Add Product Parameter'}</span>
                  </button>
                </div>
              ) : viewMode === 'blocks' ? (
                /* Block Grid */
                <div style={{ padding: '20px 24px' }}>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
                    {parameters.map((p, i) => {
                      const mtype = (p.measurement_type || '').toLowerCase();
                      const isVisual = mtype === 'visual';
                      const isLimit  = mtype === 'max_limit' || mtype === 'min_limit' || mtype === 'surface';
                      const ruleLabel  = isVisual ? 'Rule 2: Visual YES/NO' : isLimit ? 'Rule 3: Limit' : 'Rule 1: Range';

                      return (
                        <div key={p.id} style={{
                          background: '#FFFFFF',
                          border: `1px solid ${p.is_critical ? '#FECACA' : '#E2E8F0'}`,
                          borderLeft: `4px solid ${p.is_critical ? '#DC2626' : '#0F172A'}`,
                          borderRadius: 8,
                          boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                          display: 'flex', flexDirection: 'column',
                          overflow: 'hidden',
                        }}>
                          {/* Card Header */}
                          <div style={{
                            padding: '12px 14px 10px',
                            background: p.is_critical ? '#FFF5F5' : '#FAFBFC',
                            borderBottom: '1px solid #F1F5F9',
                            display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                          }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                              <span style={{
                                background: '#0F172A', color: '#FFFFFF',
                                padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 700, letterSpacing: '0.3px'
                              }}>P{p.sequence_order || (i + 1)}</span>
                              <span style={{
                                background: '#F1F5F9', color: '#475569', border: '1px solid #E2E8F0',
                                padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 600
                              }}>{ruleLabel}</span>
                            </div>
                            {p.is_critical && (
                              <span style={{
                                background: '#FEF2F2', color: '#DC2626', border: '1px solid #FECACA',
                                padding: '2px 7px', borderRadius: 4, fontSize: 10, fontWeight: 700
                              }}>CRITICAL</span>
                            )}
                          </div>

                          {/* Card Body */}
                          <div style={{ padding: '14px', flex: 1 }}>
                            <div style={{ fontSize: 14, fontWeight: 700, color: '#0F172A', marginBottom: 12 }}>
                              {p.parameter_name}
                            </div>

                            {!isVisual && (
                              <>
                                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.2fr 1fr', gap: 6, marginBottom: 10 }}>
                                  <div style={{ textAlign: 'center' }}>
                                    <div style={{ fontSize: 10, fontWeight: 600, color: '#64748B', textTransform: 'uppercase', marginBottom: 4 }}>Upper Tol</div>
                                    <div style={{
                                      background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                      padding: '6px 4px', fontFamily: 'monospace', fontSize: 13, fontWeight: 700, color: '#0F172A'
                                    }}>+{p.upper_tolerance}</div>
                                  </div>
                                  <div style={{ textAlign: 'center' }}>
                                    <div style={{ fontSize: 10, fontWeight: 600, color: '#64748B', textTransform: 'uppercase', marginBottom: 4 }}>Nominal</div>
                                    <div style={{
                                      background: '#FFFFFF', border: '1px solid #CBD5E1', borderRadius: 6,
                                      padding: '6px 4px', fontFamily: 'monospace', fontSize: 13, fontWeight: 700, color: '#0F172A'
                                    }}>{p.nominal_value} <span style={{ fontSize: 11, color: '#64748B', fontWeight: 500 }}>{p.unit}</span></div>
                                  </div>
                                  <div style={{ textAlign: 'center' }}>
                                    <div style={{ fontSize: 10, fontWeight: 600, color: '#64748B', textTransform: 'uppercase', marginBottom: 4 }}>Lower Tol</div>
                                    <div style={{
                                      background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                      padding: '6px 4px', fontFamily: 'monospace', fontSize: 13, fontWeight: 700, color: '#0F172A'
                                    }}>{p.lower_tolerance}</div>
                                  </div>
                                </div>

                                <div style={{
                                  background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                  padding: '7px 12px', marginBottom: 10, textAlign: 'center',
                                  fontFamily: 'monospace', fontSize: 12, fontWeight: 600, color: '#0F172A'
                                }}>
                                  Allowed: {p.lower_limit} to {p.upper_limit} {p.unit}
                                </div>
                              </>
                            )}

                            {isVisual && (
                              <div style={{
                                background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                padding: '10px', marginBottom: 10, textAlign: 'center'
                              }}>
                                <div style={{ fontSize: 12, fontWeight: 700, color: '#0F172A' }}>VISUAL INSPECTION</div>
                                <div style={{ fontSize: 11, color: '#64748B', marginTop: 2 }}>Operator records PASS / FAIL</div>
                                <div style={{ display: 'flex', justifyContent: 'center', gap: 8, marginTop: 6 }}>
                                  <span style={{ background: '#F0FDF4', color: '#15803D', border: '1px solid #BBF7D0', padding: '2px 10px', borderRadius: 4, fontSize: 11, fontWeight: 700 }}>YES = PASS</span>
                                  <span style={{ background: '#FEF2F2', color: '#B91C1C', border: '1px solid #FECACA', padding: '2px 10px', borderRadius: 4, fontSize: 11, fontWeight: 700 }}>NO = FAIL</span>
                                </div>
                              </div>
                            )}

                            {isLimit && (
                              <div style={{
                                background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                padding: '8px 10px', marginBottom: 10, textAlign: 'center'
                              }}>
                                <div style={{ fontSize: 12, fontWeight: 600, color: '#0F172A' }}>
                                  {mtype === 'min_limit' ? `Minimum: ${p.nominal_value} ${p.unit}` : `Maximum: ${p.nominal_value} ${p.unit}`}
                                </div>
                              </div>
                            )}

                            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                              {p.measurement_technique && (
                                <span style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 500 }}>
                                  {p.measurement_technique}
                                </span>
                              )}
                              {p.sample_size && (
                                <span style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 500 }}>
                                  {p.sample_size}
                                </span>
                              )}
                              {p.control_method && (
                                <span style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 500 }}>
                                  {p.control_method}
                                </span>
                              )}
                            </div>
                          </div>

                          {/* Card Footer: Actions */}
                          <div style={{
                            padding: '8px 14px', borderTop: '1px solid #F1F5F9',
                            display: 'flex', justifyContent: 'flex-end', gap: 6, background: '#FAFBFC'
                          }}>
                            <button
                              type="button"
                              onClick={() => handleEditParamWithLockCheck(p)}
                              style={{
                                padding: '5px 12px', fontSize: 12, fontWeight: 600,
                                background: '#FFFFFF', border: '1px solid #CBD5E1',
                                borderRadius: 5, color: '#334155', cursor: 'pointer',
                                display: 'inline-flex', alignItems: 'center', gap: 4
                              }}
                            >
                              {isApproved && <Lock size={11} />}
                              <span>{isApproved ? 'Change (DCR)' : 'Edit'}</span>
                            </button>
                            <button
                              type="button"
                              onClick={() => handleDeleteParamWithLockCheck(p)}
                              style={{
                                padding: '5px 12px', fontSize: 12, fontWeight: 600,
                                background: '#FFFFFF', border: '1px solid #FECACA',
                                borderRadius: 5, color: '#DC2626', cursor: 'pointer',
                                display: 'inline-flex', alignItems: 'center', gap: 4
                              }}
                            >
                              {isApproved && <Lock size={11} />}
                              <span>{isApproved ? 'Delete (DCR)' : 'Delete'}</span>
                            </button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              ) : (
                /* Table View */
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                    <thead>
                      <tr style={{ background: '#F8FAFC', borderBottom: '2px solid #E2E8F0' }}>
                        {['#', 'Parameter Name', 'Nominal', 'Tolerances', 'Allowed Range', 'Unit', 'Type', 'Status', 'Actions'].map((h) => (
                          <th key={h} style={{
                            padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 700,
                            color: '#64748B', textTransform: 'uppercase', letterSpacing: '0.8px',
                            whiteSpace: 'nowrap'
                          }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {parameters.map((p) => (
                        <tr key={p.id} style={{
                          background: '#FFFFFF',
                          borderBottom: '1px solid #F1F5F9',
                        }}>
                          <td style={{ padding: '13px 16px', color: '#94A3B8', fontWeight: 700, fontSize: 13 }}>P{p.sequence_order}</td>
                          <td style={{ padding: '13px 16px', fontWeight: 700, color: '#0F172A', fontSize: 13.5, borderLeft: '3px solid #0F172A' }}>
                            {p.parameter_name}
                          </td>
                          <td style={{ padding: '13px 16px', fontWeight: 700, color: '#1E293B', fontFamily: 'monospace', fontSize: 13 }}>{p.nominal_value}</td>
                          <td style={{ padding: '13px 16px', color: '#334155', fontWeight: 600, fontFamily: 'monospace', fontSize: 13 }}>+{p.upper_tolerance} / {p.lower_tolerance}</td>
                          <td style={{ padding: '13px 16px' }}>
                            <span style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', color: '#0F172A', padding: '3px 8px', borderRadius: 4, fontWeight: 600, fontSize: 12, fontFamily: 'monospace', whiteSpace: 'nowrap' }}>
                              {p.lower_limit} to {p.upper_limit} {p.unit}
                            </span>
                          </td>
                          <td style={{ padding: '13px 16px', color: '#64748B', fontWeight: 600, fontSize: 12 }}>{p.unit}</td>
                          <td style={{ padding: '13px 16px' }}>
                            <span style={{ background: '#F8FAFC', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 500, textTransform: 'capitalize', border: '1px solid #E2E8F0' }}>
                              {p.measurement_type}
                            </span>
                          </td>
                          <td style={{ padding: '13px 16px' }}>
                            {p.is_critical
                              ? <span style={{ background: '#FEF2F2', border: '1px solid #FECACA', color: '#DC2626', padding: '2px 8px', borderRadius: 4, fontSize: 10.5, fontWeight: 700 }}>CRITICAL</span>
                              : <span style={{ background: '#F8FAFC', color: '#64748B', border: '1px solid #E2E8F0', padding: '2px 8px', borderRadius: 4, fontSize: 10.5, fontWeight: 500 }}>Normal</span>}
                          </td>
                          <td style={{ padding: '13px 16px', textAlign: 'right' }}>
                            <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                              <button
                                type="button"
                                onClick={() => handleEditParamWithLockCheck(p)}
                                style={{ padding: '4px 10px', fontSize: 11.5, fontWeight: 600, background: '#FFFFFF', border: '1px solid #CBD5E1', borderRadius: 5, color: '#334155', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 4 }}
                              >
                                {isApproved && <Lock size={11} />}
                                <span>{isApproved ? 'Change (DCR)' : 'Edit'}</span>
                              </button>
                              <button
                                type="button"
                                onClick={() => handleDeleteParamWithLockCheck(p)}
                                style={{ padding: '4px 10px', fontSize: 11.5, fontWeight: 600, background: '#FFFFFF', border: '1px solid #FECACA', borderRadius: 5, color: '#DC2626', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 4 }}
                              >
                                {isApproved && <Lock size={11} />}
                                <span>{isApproved ? 'Delete (DCR)' : 'Delete'}</span>
                              </button>
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          ) : (
            /* ── B. PROCESS PARAMETERS SECTION ──────────────────────── */
            <div>
              <div style={{ padding: '14px 24px', background: '#F1F5F9', borderBottom: '1px solid #E2E8F0', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 800, color: '#312E81', textTransform: 'uppercase', letterSpacing: '0.5px' }}>
                    PROCESS PARAMETERS ({processParameters.length})
                  </div>
                  <div style={{ fontSize: 12, color: '#64748B', marginTop: 2 }}>
                    Setup-only parameters checked by Inspector for 1PC#1, 1PC#2, and 1PC#3 (NOT for hourly inspection)
                  </div>
                </div>
              </div>

              {processParameters.length === 0 ? (
                <div style={{ padding: '50px 40px', textAlign: 'center' }}>
                  <div style={{ fontSize: 15, fontWeight: 700, color: '#1E293B', marginBottom: 4 }}>No Process Parameters Configured</div>
                  <div style={{ fontSize: 12, color: '#64748B', marginBottom: 16 }}>
                    Click "+ Add Process Parameter" in the header toolbar above or below to configure machine setup checks (RPM, Feed, Tool Offset, Coolant, etc.).
                  </div>
                  <button
                    type="button"
                    onClick={handleOpenAddProcessParamWithLockCheck}
                    style={{
                      padding: '9px 18px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                      background: '#0F172A',
                      border: '1px solid #0F172A', color: '#FFFFFF', cursor: 'pointer',
                      boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                      display: 'inline-flex', alignItems: 'center', gap: 6,
                    }}
                  >
                    {isApproved ? <Lock size={14} /> : <Plus size={14} />}
                    <span>{isApproved ? 'Request Process Parameter (DCR)' : 'Add Process Parameter'}</span>
                  </button>
                </div>
              ) : viewMode === 'blocks' ? (
                /* Block Grid View for Process Parameters */
                <div style={{ padding: '20px 24px' }}>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
                    {processParameters.map((pp) => {
                      const isNumeric = (pp.data_type || '').toLowerCase() === 'numeric';
                      const hasLimits = pp.lower_limit != null && pp.upper_limit != null;

                      return (
                        <div key={pp.id} style={{
                          background: '#FFFFFF',
                          border: '1px solid #E2E8F0',
                          borderLeft: '4px solid #334155',
                          borderRadius: 8,
                          boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                          display: 'flex', flexDirection: 'column',
                          overflow: 'hidden',
                        }}>
                          {/* Card Header */}
                          <div style={{
                            padding: '12px 14px 10px',
                            background: '#FAFBFC',
                            borderBottom: '1px solid #F1F5F9',
                            display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                          }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                              <span style={{
                                background: '#334155', color: '#FFFFFF',
                                padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 700, fontFamily: 'monospace'
                              }}>{pp.parameter_code}</span>
                              <span style={{
                                background: '#F1F5F9', color: '#475569', border: '1px solid #E2E8F0',
                                padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 600, textTransform: 'uppercase'
                              }}>{pp.data_type || 'NUMERIC'}</span>
                            </div>
                            <span style={{
                              background: '#F8FAFC', color: '#475569', border: '1px solid #E2E8F0',
                              padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 600
                            }}>1PC SETUP ONLY</span>
                          </div>

                          {/* Card Body */}
                          <div style={{ padding: '14px', flex: 1 }}>
                            <div style={{ fontSize: 14, fontWeight: 700, color: '#0F172A', marginBottom: 12 }}>
                              {pp.parameter_name}
                            </div>

                            {/* Specification / Expected Box */}
                            <div style={{
                              background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                              padding: '8px 12px', marginBottom: 10
                            }}>
                              <div style={{ fontSize: 10, fontWeight: 600, color: '#64748B', textTransform: 'uppercase', marginBottom: 2 }}>
                                Expected Spec / Value
                              </div>
                              <div style={{ fontSize: 13, fontWeight: 700, color: '#0F172A', fontFamily: 'monospace' }}>
                                {pp.specification || '-'} {pp.unit ? <span style={{ fontSize: 11, color: '#64748B', fontWeight: 500 }}>{pp.unit}</span> : ''}
                              </div>
                            </div>

                            {/* Range / Allowed Limits */}
                            {isNumeric && hasLimits && (
                              <div style={{
                                background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 6,
                                padding: '7px 12px', marginBottom: 10, textAlign: 'center',
                                fontFamily: 'monospace', fontSize: 12, fontWeight: 600, color: '#0F172A'
                              }}>
                                Allowed Range: {pp.lower_limit} to {pp.upper_limit} {pp.unit || ''}
                              </div>
                            )}

                            {/* Info Tag */}
                            <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
                              <span style={{ background: '#F1F5F9', border: '1px solid #E2E8F0', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 10, fontWeight: 500 }}>
                                Inspector Check (1PC#1, #2, #3)
                              </span>
                            </div>
                          </div>

                          {/* Card Footer: Actions */}
                          <div style={{
                            padding: '8px 14px', borderTop: '1px solid #F1F5F9',
                            display: 'flex', justifyContent: 'flex-end', gap: 6, background: '#FAFBFC'
                          }}>
                            <button
                              type="button"
                              onClick={() => handleEditProcessParamWithLockCheck(pp)}
                              style={{
                                padding: '5px 12px', fontSize: 12, fontWeight: 600,
                                background: '#FFFFFF', border: '1px solid #CBD5E1',
                                borderRadius: 5, color: '#334155', cursor: 'pointer',
                                display: 'inline-flex', alignItems: 'center', gap: 4
                              }}
                            >
                              {isApproved && <Lock size={11} />}
                              <span>{isApproved ? 'Change (DCR)' : 'Edit'}</span>
                            </button>
                            <button
                              type="button"
                              onClick={() => handleDeleteProcessParamWithLockCheck(pp)}
                              style={{
                                padding: '5px 12px', fontSize: 12, fontWeight: 600,
                                background: '#FFFFFF', border: '1px solid #FECACA',
                                borderRadius: 5, color: '#DC2626', cursor: 'pointer',
                                display: 'inline-flex', alignItems: 'center', gap: 4
                              }}
                            >
                              {isApproved && <Lock size={11} />}
                              <span>{isApproved ? 'Delete (DCR)' : 'Delete'}</span>
                            </button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              ) : (
                /* Table View */
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                    <thead>
                      <tr style={{ background: '#F8FAFC', borderBottom: '1px solid #E2E8F0' }}>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>CODE</th>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>PROCESS PARAMETER NAME</th>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>DATA TYPE</th>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>UNIT</th>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>SPECIFICATION / EXPECTED</th>
                        <th style={{ padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: '#475569' }}>RANGE / LIMITS</th>
                        <th style={{ padding: '12px 16px', textAlign: 'right', fontSize: 11, fontWeight: 800, color: '#475569' }}>ACTIONS</th>
                      </tr>
                    </thead>
                    <tbody>
                      {processParameters.map((pp, i) => (
                        <tr key={pp.id} style={{ background: i % 2 === 0 ? '#FFFFFF' : '#F8FAFC', borderBottom: '1px solid #F1F5F9' }}>
                          <td style={{ padding: '12px 16px', fontWeight: 700, color: '#334155', fontSize: 13, fontFamily: 'monospace' }}>{pp.parameter_code}</td>
                          <td style={{ padding: '12px 16px', fontWeight: 700, color: '#0F172A', fontSize: 13.5 }}>{pp.parameter_name}</td>
                          <td style={{ padding: '12px 16px' }}>
                            <span style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', color: '#475569', padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 600, textTransform: 'uppercase' }}>
                              {pp.data_type}
                            </span>
                          </td>
                          <td style={{ padding: '12px 16px', color: '#64748B', fontSize: 12, fontWeight: 600 }}>{pp.unit || '-'}</td>
                          <td style={{ padding: '12px 16px', fontWeight: 700, color: '#1E293B', fontSize: 13 }}>{pp.specification || '-'}</td>
                          <td style={{ padding: '12px 16px', color: '#0F172A', fontFamily: 'monospace', fontSize: 12.5, fontWeight: 600 }}>
                            {pp.data_type === 'numeric' && pp.lower_limit != null && pp.upper_limit != null
                              ? `${pp.lower_limit} to ${pp.upper_limit} ${pp.unit}`
                              : '-'}
                          </td>
                          <td style={{ padding: '12px 16px', textAlign: 'right' }}>
                            <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                              <button
                                type="button"
                                onClick={() => handleEditProcessParamWithLockCheck(pp)}
                                style={{ padding: '4px 10px', fontSize: 11.5, fontWeight: 600, background: '#FFFFFF', border: '1px solid #CBD5E1', borderRadius: 5, color: '#334155', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 4 }}
                              >
                                {isApproved && <Lock size={11} />}
                                <span>{isApproved ? 'Change (DCR)' : 'Edit'}</span>
                              </button>
                              <button
                                type="button"
                                onClick={() => handleDeleteProcessParamWithLockCheck(pp)}
                                style={{ padding: '4px 10px', fontSize: 11.5, fontWeight: 600, background: '#FFFFFF', border: '1px solid #FECACA', borderRadius: 5, color: '#DC2626', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 4 }}
                              >
                                {isApproved && <Lock size={11} />}
                                <span>{isApproved ? 'Delete (DCR)' : 'Delete'}</span>
                              </button>
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}
        </div>


        {/* ── 2.5 DOCUMENT CHANGE REQUESTS (DCR LOG - FORM DKI/MR/F/05) ── */}
        {selectedTemplate && (
          <div id="dcr-section" style={{
            background: '#FFFFFF', border: '1px solid #E2E8F0', borderRadius: 14,
            padding: '20px 24px', marginBottom: 24, boxShadow: '0 2px 8px rgba(0,0,0,0.04)'
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 12 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <FileText size={18} color="#0F172A" />
                  <h3 style={{ margin: 0, fontSize: 14, fontWeight: 800, color: '#0F172A', textTransform: 'uppercase', letterSpacing: '0.6px' }}>
                    Document Change Requests (DCR Log: Form DKI/MR/F/05)
                  </h3>
                  <span style={{ background: '#F1F5F9', border: '1px solid #CBD5E1', color: '#475569', fontSize: 11, fontWeight: 700, padding: '2px 8px', borderRadius: 10 }}>
                    {templateDCRs.length} Recorded
                  </span>
                </div>
                <div style={{ fontSize: 12, color: '#64748B', marginTop: 3 }}>
                  Mandatory engineering & quality change control procedure for approved inspection sheets.
                </div>
              </div>
              <button
                type="button"
                onClick={handleOpenGeneralDCRModal}
                style={{
                  padding: '8px 16px', borderRadius: 8, fontSize: 12, fontWeight: 700,
                  background: '#0F172A', color: '#FFFFFF', border: 'none', cursor: 'pointer',
                  display: 'flex', alignItems: 'center', gap: 6, boxShadow: '0 2px 6px rgba(15,23,42,0.15)'
                }}
              >
                <Plus size={14} />
                <span>Initiate DCR (Form DKI/MR/F/05)</span>
              </button>
            </div>

            {loadingDCRs ? (
              <div style={{ padding: '24px', textAlign: 'center', color: '#64748B', fontSize: 12.5 }}>
                Loading change requests...
              </div>
            ) : templateDCRs.length === 0 ? (
              <div style={{ padding: '28px 20px', textAlign: 'center', background: '#F8FAFC', borderRadius: 10, border: '1px dashed #CBD5E1' }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: '#475569', marginBottom: 3 }}>
                  No Document Change Requests Filed
                </div>
                <div style={{ fontSize: 11.5, color: '#94A3B8' }}>
                  This operation is currently operating under baseline revision. Any future modifications to approved parameters will be logged here.
                </div>
              </div>
            ) : (
              <div style={{ overflowX: 'auto', border: '1px solid #E2E8F0', borderRadius: 10 }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                  <thead>
                    <tr style={{ background: '#F8FAFC', borderBottom: '1px solid #E2E8F0', textAlign: 'left', color: '#64748B', fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.6px' }}>
                      <th style={{ padding: '10px 14px' }}>DCR Number</th>
                      <th style={{ padding: '10px 14px' }}>Date</th>
                      <th style={{ padding: '10px 14px' }}>Type</th>
                      <th style={{ padding: '10px 14px' }}>Parameter</th>
                      <th style={{ padding: '10px 14px' }}>Current Specification</th>
                      <th style={{ padding: '10px 14px' }}>Proposed Specification</th>
                      <th style={{ padding: '10px 14px' }}>Basis for Change</th>
                      <th style={{ padding: '10px 14px' }}>Raised By</th>
                      <th style={{ padding: '10px 14px' }}>Status</th>
                      <th style={{ padding: '10px 14px', textAlign: 'right' }}>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {templateDCRs.map((dcr) => (
                      <tr key={dcr.id} style={{ borderBottom: '1px solid #F1F5F9', background: '#FFFFFF' }}>
                        <td style={{ padding: '11px 14px', fontWeight: 700, color: '#0F172A', fontFamily: 'monospace' }}>
                          {dcr.dcr_number}
                        </td>
                        <td style={{ padding: '11px 14px', color: '#64748B', whiteSpace: 'nowrap' }}>
                          {dcr.created_at ? new Date(dcr.created_at).toLocaleDateString() : '-'}
                        </td>
                        <td style={{ padding: '11px 14px' }}>
                          <span style={{
                            padding: '2px 8px', borderRadius: 6, fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase',
                            background: dcr.change_type === 'addition' ? '#EFF6FF' : dcr.change_type === 'deletion' ? '#FEF2F2' : '#F5F3FF',
                            color: dcr.change_type === 'addition' ? '#1D4ED8' : dcr.change_type === 'deletion' ? '#DC2626' : '#6D28D9',
                            border: `1px solid ${dcr.change_type === 'addition' ? '#BFDBFE' : dcr.change_type === 'deletion' ? '#FECACA' : '#DDD6FE'}`
                          }}>
                            {dcr.change_type}
                          </span>
                        </td>
                        <td style={{ padding: '11px 14px', fontWeight: 600, color: '#1E293B' }}>
                          {dcr.parameter_code ? `[${dcr.parameter_code}] ` : ''}{dcr.parameter_name || 'N/A'}
                          {dcr.is_process_parameter && (
                            <span style={{ marginLeft: 6, fontSize: 10, color: '#4F46E5', fontWeight: 700 }}>PROCESS</span>
                          )}
                        </td>
                        <td style={{ padding: '11px 14px', color: '#64748B', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={typeof dcr.current_specification === 'object' ? JSON.stringify(dcr.current_specification) : dcr.current_specification}>
                          {formatSpecification(dcr.current_specification)}
                        </td>
                        <td style={{ padding: '11px 14px', fontWeight: 600, color: '#0F172A', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={typeof dcr.proposed_specification === 'object' ? JSON.stringify(dcr.proposed_specification) : dcr.proposed_specification}>
                          {formatSpecification(dcr.proposed_specification)}
                        </td>
                        <td style={{ padding: '11px 14px', color: '#475569', maxWidth: 160, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={dcr.basis_for_change}>
                          {dcr.basis_for_change || '-'}
                        </td>
                        <td style={{ padding: '11px 14px', color: '#64748B', whiteSpace: 'nowrap' }}>
                          {dcr.raised_by_name || 'System'}
                        </td>
                        <td style={{ padding: '11px 14px' }}>
                          <span style={{
                            padding: '2px 8px', borderRadius: 12, fontSize: 10.5, fontWeight: 700,
                            background:
                              dcr.status === 'approved' ? '#DCFCE7' :
                              dcr.status === 'reviewed' ? '#E0E7FF' :
                              dcr.status === 'rejected' ? '#FEE2E2' : '#FEF3C7',
                            color:
                              dcr.status === 'approved' ? '#15803D' :
                              dcr.status === 'reviewed' ? '#4338CA' :
                              dcr.status === 'rejected' ? '#B91C1C' : '#B45309',
                            border: `1px solid ${
                              dcr.status === 'approved' ? '#BBF7D0' :
                              dcr.status === 'reviewed' ? '#C7D2FE' :
                              dcr.status === 'rejected' ? '#FCA5A5' : '#FDE68A'
                            }`
                          }}>
                            {dcr.status_display || dcr.status.toUpperCase()}
                          </span>
                        </td>
                        <td style={{ padding: '11px 14px', textAlign: 'right', whiteSpace: 'nowrap' }}>
                          <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                            {(dcr.status === 'submitted' || dcr.status === 'awaiting_review') && (
                              <button
                                type="button"
                                onClick={() => handleOpenDCRReviewModal(dcr)}
                                style={{
                                  padding: '4px 10px', fontSize: 11, fontWeight: 700, borderRadius: 6,
                                  background: '#FFFBEB', border: '1px solid #FDE68A', color: '#B45309', cursor: 'pointer'
                                }}
                              >
                                Review
                              </button>
                            )}
                            {(dcr.status === 'reviewed' || (isAdmin && dcr.status !== 'approved' && dcr.status !== 'rejected')) && (
                              <button
                                type="button"
                                onClick={() => handleOpenDCRApproveModal(dcr)}
                                style={{
                                  padding: '4px 10px', fontSize: 11, fontWeight: 700, borderRadius: 6,
                                  background: '#F0FDF4', border: '1px solid #BBF7D0', color: '#15803D', cursor: 'pointer'
                                }}
                              >
                                Approve
                              </button>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {/* ── 3. CONFIGURATION STATUS CARD ────────────────────────── */}
        {selectedTemplate && (() => {
          const target = selectedTemplate?.target_parameter_count || 10;
          const current = parameters.length;
          const pct = Math.min(Math.round((current / target) * 100), 100);
          const complete = current >= target;

          return (
            <div style={{
              background: '#FFFFFF', border: '1px solid #E2E8F0', borderRadius: 14,
              padding: '20px 24px', marginBottom: 24, boxShadow: '0 2px 8px rgba(0,0,0,0.04)'
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 800, color: '#0F172A', textTransform: 'uppercase', letterSpacing: '0.8px', marginBottom: 4 }}>
                    CONFIGURATION STATUS
                  </div>
                  <div style={{ fontSize: 13, fontWeight: 700, color: complete ? '#059669' : '#0284C7' }}>
                    {current} / {target} Parameters Configured ({pct}%)
                  </div>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  {complete ? (
                    <span style={{ background: '#F0FDF4', color: '#15803D', border: '1px solid #BBF7D0', padding: '4px 12px', borderRadius: 20, fontSize: 11, fontWeight: 800 }}>
                      Complete
                    </span>
                  ) : (
                    <span style={{ background: '#FFFBEB', color: '#D97706', border: '1px solid #FDE68A', padding: '4px 12px', borderRadius: 20, fontSize: 11, fontWeight: 800 }}>
                      In Progress
                    </span>
                  )}
                </div>
              </div>

              <div style={{ width: '100%', height: 6, background: '#E2E8F0', borderRadius: 4, overflow: 'hidden' }}>
                <div style={{
                  width: `${pct}%`, height: '100%', borderRadius: 4,
                  background: complete ? '#15803D' : '#0F172A',
                  transition: 'width 0.3s ease'
                }} />
              </div>
            </div>
          );
        })()}

        {/* ── 4. MOBILE DEPLOYMENT CARD ──────────────────────────── */}
        {selectedTemplate && (() => {
          const current = parameters.length;
          const isPublished = selectedTemplate?.is_published;

          return (
            <div style={{
              background: '#FFFFFF', border: '1px solid #E2E8F0', borderRadius: 14,
              padding: '20px 24px', marginBottom: 24, boxShadow: '0 2px 8px rgba(0,0,0,0.04)'
            }}>
              <div style={{ fontSize: 12, fontWeight: 800, color: '#0F172A', textTransform: 'uppercase', letterSpacing: '0.8px', marginBottom: 12 }}>
                MOBILE DEPLOYMENT
              </div>

              <div style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '14px 18px', borderRadius: 8, flexWrap: 'wrap', gap: 14,
                background: '#F8FAFC',
                border: '1px solid #E2E8F0',
              }}>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <span style={{
                      fontSize: 13.5, fontWeight: 700,
                      color: '#0F172A'
                    }}>
                      Status: {(isPublished || selectedTemplate?.status === 'approved') ? 'Dispatched & Live on Mobile' :
                               selectedTemplate?.status === 'reviewed' ? 'Reviewed: Ready for Final Sign-Off' :
                               selectedTemplate?.status === 'under_review' ? 'Under Review: Quality Check in Progress' :
                               selectedTemplate?.status === 'rejected' ? 'Rejected: Modifications Required' : 'Draft: Pending Review Submission'}
                    </span>
                    <span style={{
                      padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 600,
                      background: '#F1F5F9',
                      color: '#475569',
                      border: '1px solid #E2E8F0'
                    }}>
                      {selectedMachine?.machine_code || 'CNC-01'} : Operator & Quality Inspector
                    </span>
                  </div>
                  <div style={{
                    fontSize: 12,
                    color: '#64748B',
                    marginTop: 4
                  }}>
                    {(isPublished || selectedTemplate?.status === 'approved')
                      ? `All configured parameters are authorized and live on shop floor mobile devices for ${selectedPart?.part_number}.`
                      : selectedTemplate?.status === 'reviewed'
                      ? `Parameters reviewed and recommended. Final sign-off will automatically broadcast parameters to mobile devices.`
                      : selectedTemplate?.status === 'under_review'
                      ? `Template is currently under review by ${selectedTemplate.assigned_reviewer_name || 'assigned reviewer'}.`
                      : selectedTemplate?.status === 'rejected'
                      ? `Modifications requested: "${selectedTemplate.rejection_reason || 'See review notes'}". Please correct and resubmit.`
                      : `Submit this operation for 3-tier sign-off to authorize broadcast to mobile shop floor.`}
                  </div>
                </div>

                <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                  {/* Primary context button depending on status */}
                  {selectedTemplate?.status === 'reviewed' ? (
                    <button
                      type="button"
                      onClick={handleOpenApproveModal}
                      style={{
                        padding: '8px 18px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                        background: '#15803D',
                        border: '1px solid #166534',
                        color: '#FFFFFF', cursor: 'pointer',
                        boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                        display: 'flex', alignItems: 'center', gap: 6,
                      }}
                    >
                      <CheckCircle2 size={14} />
                      <span>Final Approve & Dispatch</span>
                    </button>
                  ) : selectedTemplate?.status === 'under_review' ? (
                    <button
                      type="button"
                      onClick={handleOpenReviewModal}
                      style={{
                        padding: '8px 18px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                        background: '#D97706',
                        border: '1px solid #B45309',
                        color: '#FFFFFF', cursor: 'pointer',
                        boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                        display: 'flex', alignItems: 'center', gap: 6,
                      }}
                    >
                      <Eye size={14} />
                      <span>Review & Recommend</span>
                    </button>
                  ) : (!selectedTemplate?.status || selectedTemplate?.status === 'draft' || selectedTemplate?.status === 'rejected') ? (
                    <button
                      type="button"
                      onClick={handleInitiateSubmitReview}
                      title={isAllParametersFilled ? "Submit for quality review" : `Configure all ${targetRequiredParams} parameters before submitting`}
                      style={{
                        padding: '8px 18px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                        background: isAllParametersFilled ? '#2563EB' : '#94A3B8',
                        border: isAllParametersFilled ? '1px solid #1D4ED8' : '1px solid #94A3B8',
                        color: '#FFFFFF', cursor: 'pointer',
                        boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                        display: 'flex', alignItems: 'center', gap: 6,
                      }}
                    >
                      <FileText size={14} />
                      <span>Submit for Quality Sign-Off ({totalConfiguredParams}/{targetRequiredParams})</span>
                    </button>
                  ) : null}

                  {/* Direct Publish / Re-Dispatch button */}
                  <button
                    type="button"
                      onClick={() => { if (requireManageAccess('publish an operation')) setShowPublishModal(true); }}
                    style={{
                      padding: '8px 16px', fontWeight: 600, borderRadius: 6, fontSize: 12.5,
                      background: '#FFFFFF',
                      color: '#334155',
                      border: '1px solid #CBD5E1',
                      cursor: 'pointer',
                      display: 'flex', alignItems: 'center', gap: 6,
                    }}
                  >
                    <RefreshCw size={13} />
                    <span>{(isPublished || selectedTemplate?.status === 'approved') ? 'Re-Dispatch to Mobile' : 'Direct Dispatch (Admin)'}</span>
                  </button>
                </div>
              </div>
            </div>
          );
        })()}

        {/* Modal 1: Add / Edit Machine */}
        {showAddMachineModal && (
          <div className="modal-overlay" onClick={() => setShowAddMachineModal(false)}>
            <div className="modal-content" style={{ maxWidth: 400 }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>{editingMachine ? `Edit Machine: ${editingMachine.machine_code}` : 'Add New Machine'}</h3>
                <button type="button" className="btn-close" onClick={() => setShowAddMachineModal(false)}>×</button>
              </div>
              <form onSubmit={handleSaveMachine}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div>
                    <label className="form-label">Machine Code *</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder="e.g. CNC-01, VMC-02"
                      value={machineForm.machine_code}
                      onChange={(e) => setMachineForm({ ...machineForm, machine_code: e.target.value })}
                      required
                    />
                  </div>
                  <div>
                    <label className="form-label">Machine Name</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder="e.g. CNC Turning Center"
                      value={machineForm.name}
                      onChange={(e) => setMachineForm({ ...machineForm, name: e.target.value })}
                    />
                  </div>
                </div>
                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowAddMachineModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">{editingMachine ? 'Update Machine' : 'Save Machine'}</button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Modal 2: Add / Edit Part */}
        {showAddPartModal && selectedMachine && (
          <div className="modal-overlay" onClick={() => setShowAddPartModal(false)}>
            <div className="modal-content" style={{ maxWidth: 440 }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>{editingPart ? `Edit Part: ${editingPart.part_number}` : `Add Part to Machine [${selectedMachine.machine_code}]`}</h3>
                <button type="button" className="btn-close" onClick={() => setShowAddPartModal(false)}>×</button>
              </div>
              <form onSubmit={handleSavePart}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div>
                    <label className="form-label">Part Number *</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder="e.g. PN-99001"
                      value={partForm.part_number}
                      onChange={(e) => setPartForm({ ...partForm, part_number: e.target.value })}
                      required
                      disabled={!!editingPart}
                    />
                  </div>
                  <div>
                    <label className="form-label">Part Name *</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder="e.g. Drive Shaft Pulley"
                      value={partForm.part_name}
                      onChange={(e) => setPartForm({ ...partForm, part_name: e.target.value })}
                      required
                    />
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                    <div>
                      <label className="form-label">Drawing No</label>
                      <input
                        type="text"
                        className="form-input"
                        value={partForm.drawing_number}
                        onChange={(e) => setPartForm({ ...partForm, drawing_number: e.target.value })}
                      />
                    </div>
                    <div>
                      <label className="form-label">Revision</label>
                      <input
                        type="text"
                        className="form-input"
                        value={partForm.revision}
                        onChange={(e) => setPartForm({ ...partForm, revision: e.target.value })}
                      />
                    </div>
                  </div>
                </div>
                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowAddPartModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">{editingPart ? 'Update Part' : 'Save Part'}</button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Modal 3: Add Operation */}
        {showAddOpModal && selectedPart && (
          <div className="modal-overlay" onClick={() => setShowAddOpModal(false)}>
            <div className="modal-content" style={{ maxWidth: 480 }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>Add Operation Stage for [{selectedPart.part_number}]</h3>
                <button type="button" className="btn-close" onClick={() => setShowAddOpModal(false)}>×</button>
              </div>
              <form onSubmit={handleSaveOperation}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold' }}>
                      Operation Name / Process Title *
                    </label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder="e.g. Op 10 - Rough Turning, Op 20 - Finish Grooving"
                      value={newOpName}
                      onChange={(e) => setNewOpName(e.target.value)}
                      required
                    />
                    
                    {/* Preset Buttons */}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginTop: 8 }}>
                      <span style={{ fontSize: 11, color: '#94A3B8', alignSelf: 'center' }}>Presets:</span>
                      {['Op 10 - Rough Turning', 'Op 20 - Finish Grooving', 'Op 30 - Drilling & Milling', 'Op 40 - Balancing Check', 'Op 50 - Final Quality Check'].map((preset) => (
                        <button
                          key={preset}
                          type="button"
                          className="btn btn-ghost btn-sm"
                          style={{ padding: '2px 8px', fontSize: 11, background: '#1E293B', border: '1px solid #334155', color: '#38BDF8' }}
                          onClick={() => setNewOpName(preset)}
                        >
                          + {preset}
                        </button>
                      ))}
                    </div>
                  </div>

                  <div>
                    <label className="form-label">Inspection Category Sheet</label>
                    <select className="form-select" value={newOpType} onChange={(e) => setNewOpType(e.target.value)}>
                      <option value="first_piece">First Piece Sheet (Oper 10)</option>
                      <option value="hourly">Hourly In-Process Sheet (Oper 20)</option>
                      <option value="final">Final Quality Check Sheet (Oper 30)</option>
                    </select>
                  </div>

                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold' }}>
                      Target Parameters Count (e.g. 18, 10, 4) *
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="100"
                      className="form-input"
                      value={newOpTargetCount}
                      onChange={(e) => setNewOpTargetCount(parseInt(e.target.value) || 1)}
                      required
                    />
                    <small style={{ color: '#94A3B8', fontSize: 12, marginTop: 4, display: 'block' }}>
                      Set expected parameter count for this operation (e.g. 18 parameters for full check).
                    </small>
                  </div>

                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold' }}>
                      Cycle Time (Minutes)
                    </label>
                    <input
                      type="number"
                      step="0.1"
                      min="0"
                      className="form-input"
                      value={newOpCycleTime}
                      onChange={(e) => setNewOpCycleTime(e.target.value)}
                    />
                    <small style={{ color: '#94A3B8', fontSize: 12, marginTop: 4, display: 'block' }}>
                      Time taken for one operation cycle in minutes.
                    </small>
                  </div>
                </div>
                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowAddOpModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">Add Operation</button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Modal 4: Add / Edit Parameter */}
        {showAddParamModal && selectedTemplate && (
          <div className="modal-overlay" onClick={() => setShowAddParamModal(false)}>
            <div className="modal-content parameter-rule-editor-modal" onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>{editingParam ? `Edit Parameter Rule` : `Add Parameter Rule to [${selectedTemplate?.inspection_type?.toUpperCase()}]`}</h3>
                <button type="button" className="btn-close" onClick={() => setShowAddParamModal(false)}>×</button>
              </div>
              <form onSubmit={handleSaveParam}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  
                  {/* 3 SPECIFICATION RULES SELECTOR */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold', marginBottom: 6, display: 'block' }}>
                      Select Quality Inspection Rule *
                    </label>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                      <button
                        type="button"
                        className={`btn btn-sm ${ruleMode === 'rule1' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: ruleMode === 'rule1' ? '2px solid #38BDF8' : '1px solid #334155' }}
                        onClick={() => selectRuleMode('rule1')}
                      >
                        Rule 1: Range (&gt; Limit &lt;)
                      </button>
                      <button
                        type="button"
                        className={`btn btn-sm ${ruleMode === 'rule2' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: ruleMode === 'rule2' ? '2px solid #10B981' : '1px solid #334155' }}
                        onClick={() => selectRuleMode('rule2')}
                      >
                        Rule 2: Visual (YES/NO)
                      </button>
                      <button
                        type="button"
                        className={`btn btn-sm ${ruleMode === 'rule3' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: ruleMode === 'rule3' ? '2px solid #F59E0B' : '1px solid #334155' }}
                        onClick={() => selectRuleMode('rule3')}
                      >
                        Rule 3: Limit (&le; or &ge;)
                      </button>
                    </div>
                  </div>

                  <div>
                    <label className="form-label">Parameter Name *</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder={
                        ruleMode === 'rule1' ? 'e.g. Bore Diameter, Total Length' :
                        ruleMode === 'rule2' ? 'e.g. Chamfer & Deburring Check' : 'e.g. Surface Finish (Ra)'
                      }
                      value={paramForm.parameter_name}
                      onChange={(e) => setParamForm({ ...paramForm, parameter_name: e.target.value })}
                      required
                    />
                  </div>

                  {/* RULE 1 FIELDS */}
                  {ruleMode === 'rule1' && (
                    <>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
                        <div>
                          <label className="form-label">Nominal Target *</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={paramForm.nominal_value}
                            onChange={(e) => setParamForm({ ...paramForm, nominal_value: e.target.value })}
                            required
                          />
                        </div>
                        <div>
                          <label className="form-label">Upper Tol (+)</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={paramForm.upper_tolerance}
                            onChange={(e) => setParamForm({ ...paramForm, upper_tolerance: e.target.value })}
                            required
                          />
                        </div>
                        <div>
                          <label className="form-label">Lower Tol (-)</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={paramForm.lower_tolerance}
                            onChange={(e) => setParamForm({ ...paramForm, lower_tolerance: e.target.value })}
                            required
                          />
                        </div>
                      </div>
                      <div style={{ background: '#0F172A', padding: 10, borderRadius: 6, fontSize: 13, color: '#38BDF8', fontWeight: 'bold' }}>
                        Rule 1 Range: [{(nom + lowerT).toFixed(4)} {paramForm.unit}] to [{(nom + upperT).toFixed(4)} {paramForm.unit}]
                      </div>
                    </>
                  )}

                  {/* RULE 2 FIELDS */}
                  {ruleMode === 'rule2' && (
                    <div>
                      <label className="form-label">Master Value / Visual Specification *</label>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="e.g. 0.5 x 45° Chamfer, No burrs, Surface smooth"
                        value={paramForm.nominal_value || ''}
                        onChange={(e) => setParamForm({ ...paramForm, nominal_value: e.target.value })}
                        required
                      />
                      <div style={{ marginTop: 6, fontSize: 11, color: '#64748B' }}>
                        Inspector sees this value and records <strong>YES (Pass)</strong> or <strong>NO (Fail)</strong>
                      </div>
                    </div>
                  )}


                  {/* RULE 3 FIELDS */}
                  {ruleMode === 'rule3' && (
                    <>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                        <div>
                          <label className="form-label">Threshold Type</label>
                          <select
                            className="form-select"
                            value={paramForm.measurement_type}
                            onChange={(e) => setParamForm({ ...paramForm, measurement_type: e.target.value })}
                          >
                            <option value="max_limit">≤ Maximum Limit (e.g. ≤ 1.60 Ra)</option>
                            <option value="min_limit">≥ Minimum Limit (e.g. ≥ 5.00 mm)</option>
                            <option value="surface">≤ Surface Finish (Ra)</option>
                          </select>
                        </div>
                        <div>
                          <label className="form-label">Threshold Value *</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={paramForm.nominal_value}
                            onChange={(e) => setParamForm({
                              ...paramForm,
                              nominal_value: e.target.value,
                              upper_tolerance: '0.00',
                              lower_tolerance: '0.00',
                            })}
                            required
                          />
                        </div>
                      </div>
                      <div style={{ background: '#0F172A', padding: 10, borderRadius: 6, fontSize: 13, color: '#F59E0B', fontWeight: 'bold' }}>
                        Rule 3 Threshold: {paramForm.measurement_type === 'min_limit' ? `≥ ${nom.toFixed(4)} ${paramForm.unit}` : `≤ ${nom.toFixed(4)} ${paramForm.unit}`}
                      </div>
                    </>
                  )}

                  {/* Unit + Type row */}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                    <div>
                      <label className="form-label">Unit</label>
                      <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap', marginBottom: 6 }}>
                        {['mm', '°', 'R', 'φ', 'µm', 'Ra', 'mm/rev', 'inch'].map((u) => {
                          const isSelected = paramForm.unit === u;
                          return (
                            <button
                              key={u}
                              type="button"
                              onClick={() => setParamForm({ ...paramForm, unit: u })}
                              style={{
                                padding: '4px 10px', fontSize: 12, fontWeight: 700,
                                borderRadius: 16, border: '1px solid',
                                cursor: 'pointer', transition: 'all 0.15s ease',
                                background: isSelected ? '#0F172A' : '#F8FAFC',
                                color: isSelected ? '#FFFFFF' : '#475569',
                                borderColor: isSelected ? '#0F172A' : '#CBD5E1',
                                boxShadow: isSelected ? '0 1px 3px rgba(0,0,0,0.15)' : 'none',
                              }}
                            >{u}</button>
                          );
                        })}
                      </div>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="Custom unit if not listed above..."
                        value={paramForm.unit}
                        onChange={(e) => setParamForm({ ...paramForm, unit: e.target.value })}
                        style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                      />
                    </div>
                    <div>
                      <label className="form-label">Measurement Type Code</label>
                      <input
                        type="text"
                        className="form-input"
                        value={paramForm.measurement_type}
                        readOnly
                        style={{ opacity: 0.75, textTransform: 'uppercase', background: '#F1F5F9', border: '1px solid #CBD5E1', color: '#475569', borderRadius: 8, padding: '9px 12px', fontSize: 13, width: '100%' }}
                      />
                    </div>
                  </div>

                  {/* ── CONTROL PLAN COLUMNS ──────────────────── */}
                  <div style={{ borderTop: '1.5px solid #E2E8F0', paddingTop: 14 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: '#0284C7', textTransform: 'uppercase', letterSpacing: '0.8px', marginBottom: 10 }}>
                      Control Plan Details
                    </div>

                    {/* Measurement Technique */}
                    <div style={{ marginBottom: 12 }}>
                      <label className="form-label" style={{ marginBottom: 4 }}>Evaluation / Measurement Technique</label>
                      <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap', marginBottom: 6 }}>
                        {['DEPTH VERNIER', 'VERNIER CALIPER', 'VISUALLY', 'PLUGE GAUGE', 'PROFILE PROJECTOR', 'COMPARE WITH MASTER', 'HEIGHT GAUGE', 'MICROMETER'].map((t) => {
                          const isSel = paramForm.measurement_technique === t;
                          return (
                            <button
                              key={t}
                              type="button"
                              onClick={() => setParamForm({ ...paramForm, measurement_technique: t })}
                              style={{
                                padding: '4px 9px', fontSize: 11, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                background: isSel ? '#0284C7' : '#F8FAFC',
                                border: isSel ? '1px solid #0284C7' : '1px solid #CBD5E1',
                                color: isSel ? '#FFFFFF' : '#475569',
                                transition: 'all 0.15s ease',
                              }}
                            >{t}</button>
                          );
                        })}
                      </div>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="Or custom instrument..."
                        value={paramForm.measurement_technique}
                        onChange={(e) => setParamForm({ ...paramForm, measurement_technique: e.target.value })}
                        style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                      />
                    </div>

                    {/* Sample Size + Control Method in 2 cols */}
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                      <div>
                        <label className="form-label" style={{ marginBottom: 4 }}>Sample Size / Frequency</label>
                        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 6 }}>
                          {['5NOS/SHIFT', '100%', 'LAYOUT INSPECTION', '1st PC/SHIFT'].map((s) => {
                            const isSel = paramForm.sample_size === s;
                            return (
                              <button
                                key={s}
                                type="button"
                                onClick={() => setParamForm({ ...paramForm, sample_size: s })}
                                style={{
                                  padding: '3px 8px', fontSize: 10.5, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                  background: isSel ? '#059669' : '#F8FAFC',
                                  border: isSel ? '1px solid #059669' : '1px solid #CBD5E1',
                                  color: isSel ? '#FFFFFF' : '#475569',
                                  transition: 'all 0.15s ease',
                                }}
                              >{s}</button>
                            );
                          })}
                        </div>
                        <input
                          type="text"
                          className="form-input"
                          placeholder="e.g. 5NOS/SHIFT"
                          value={paramForm.sample_size}
                          onChange={(e) => setParamForm({ ...paramForm, sample_size: e.target.value })}
                          style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                        />
                      </div>
                      <div>
                        <label className="form-label" style={{ marginBottom: 4 }}>Control Method</label>
                        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 6 }}>
                          {['1st PIECE & INPROCESS INSP.', 'LAYOUT INSPECTION'].map((c) => {
                            const isSel = paramForm.control_method === c;
                            return (
                              <button
                                key={c}
                                type="button"
                                onClick={() => setParamForm({ ...paramForm, control_method: c })}
                                style={{
                                  padding: '3px 8px', fontSize: 10.5, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                  background: isSel ? '#7C3AED' : '#F8FAFC',
                                  border: isSel ? '1px solid #7C3AED' : '1px solid #CBD5E1',
                                  color: isSel ? '#FFFFFF' : '#475569',
                                  transition: 'all 0.15s ease',
                                }}
                              >{c}</button>
                            );
                          })}
                        </div>
                        <input
                          type="text"
                          className="form-input"
                          placeholder="e.g. 1st PIECE & INPROCESS INSP."
                          value={paramForm.control_method}
                          onChange={(e) => setParamForm({ ...paramForm, control_method: e.target.value })}
                          style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                        />
                      </div>
                    </div>
                  </div>

                  {/* Critical checkbox */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#FEF2F2', border: '1px solid #FECACA', borderRadius: 8, padding: '10px 12px' }}>
                    <input
                      type="checkbox"
                      id="isCritical"
                      checked={paramForm.is_critical}
                      onChange={(e) => setParamForm({ ...paramForm, is_critical: e.target.checked })}
                    />
                    <label htmlFor="isCritical" style={{ cursor: 'pointer', fontSize: 13, color: '#DC2626', fontWeight: 600 }}>
                      ◑ Mark as Special Characteristic / Critical (Triggers Supervisor Alert on Out-of-Spec)
                    </label>
                  </div>
                </div>

                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowAddParamModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">Save Parameter Rule</button>
                </div>
              </form>
            </div>
          </div>
        )}
        {/* Modal 5: Supervisor Edit Target Parameters Count & Cycle Time */}
        {showEditTargetModal && selectedTemplate && (
          <div className="modal-overlay" onClick={() => setShowEditTargetModal(false)}>
            <div className="modal-content" style={{ maxWidth: 420 }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>Operation Settings</h3>
                <button type="button" className="btn-close" onClick={() => setShowEditTargetModal(false)}>×</button>
              </div>
              <form onSubmit={handleSaveTargetCount}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div style={{ background: '#0F172A', padding: 10, borderRadius: 6, fontSize: 13, color: '#38BDF8' }}>
                    Operation: <strong>{selectedTemplate?.inspection_type.toUpperCase()}</strong> (Part {selectedPart?.part_number})
                  </div>
                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold' }}>
                      Target Parameters Count (e.g. 18, 10, 4) *
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="100"
                      className="form-input"
                      value={editTargetCount}
                      onChange={(e) => setEditTargetCount(parseInt(e.target.value) || 1)}
                      required
                    />
                    <small style={{ color: '#94A3B8', fontSize: 12, marginTop: 4, display: 'block' }}>
                      Set the required number of parameters expected for this operation sheet.
                    </small>
                  </div>
                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold' }}>
                      Cycle Time (Minutes)
                    </label>
                    <input
                      type="number"
                      step="0.1"
                      min="0"
                      className="form-input"
                      value={editCycleTime}
                      onChange={(e) => setEditCycleTime(e.target.value)}
                    />
                    <small style={{ color: '#94A3B8', fontSize: 12, marginTop: 4, display: 'block' }}>
                      Time taken for one operation cycle in minutes.
                    </small>
                  </div>
                </div>
                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowEditTargetModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">Save Settings</button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Dispatch to Mobile Confirmation Modal */}
        {showPublishModal && (
          <div className="modal-overlay" onClick={() => !isPublishing && setShowPublishModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <div>
                    <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC' }}>Publish & Dispatch to Mobile</h3>
                    <p style={{ margin: 0, fontSize: 11, color: '#94A3B8' }}>Broadcast configured parameter sheet to shop floor devices</p>
                  </div>
                </div>
                {!isPublishing && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowPublishModal(false)}>×</button>
                )}
              </div>

              <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 16 }}>
                {/* Target Scope Card */}
                <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 12, padding: '14px 16px' }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: '#64748B', textTransform: 'uppercase', marginBottom: 8, letterSpacing: '0.5px' }}>
                    Target Machine & Part
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div>
                      <div style={{ fontSize: 11, color: '#94A3B8' }}>Machine</div>
                      <div style={{ fontSize: 13, fontWeight: 700, color: '#0F172A' }}>{selectedMachine?.machine_code} · {selectedMachine?.name}</div>
                    </div>
                    <div>
                      <div style={{ fontSize: 11, color: '#94A3B8' }}>Part & Operation</div>
                      <div style={{ fontSize: 13, fontWeight: 700, color: '#0F172A' }}>{selectedPart?.part_number} · {selectedTemplate?.name || selectedTemplate?.inspection_type}</div>
                    </div>
                  </div>
                </div>

                {/* Parameters Breakdown (Both Product & Process Parameters) */}
                {(() => {
                  const allParams = [
                    ...parameters.map(p => ({ ...p, is_process: false })),
                    ...processParameters.map(p => ({ ...p, is_process: true }))
                  ];
                  const totalCount = allParams.length;

                  const isRule2 = (p) => p.measurement_type === 'visual' || p.measurement_type?.startsWith('rule2') || p.data_type === 'yes_no';
                  const isRule3 = (p) => ['min_limit', 'max_limit', 'surface'].includes(p.measurement_type?.toLowerCase()) || p.measurement_type?.startsWith('rule3');
                  const isRule1 = (p) => !isRule2(p) && !isRule3(p);

                  const rule1Count = allParams.filter(isRule1).length;
                  const rule2Count = allParams.filter(isRule2).length;
                  const rule3Count = allParams.filter(isRule3).length;
                  const criticalCount = allParams.filter((p) => p.is_critical).length;

                  return (
                    <div style={{ background: '#EFF6FF', border: '1px solid #BFDBFE', borderRadius: 12, padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 10 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span style={{ fontSize: 12, fontWeight: 800, color: '#1E40AF', textTransform: 'uppercase' }}>
                          Configured Parameters Summary
                        </span>
                        <span style={{ background: '#1D4ED8', color: '#fff', padding: '3px 12px', borderRadius: 20, fontSize: 11, fontWeight: 800 }}>
                          {totalCount} Total Parameters ({parameters.length} Product + {processParameters.length} Process)
                        </span>
                      </div>

                      {/* Rule Cards */}
                      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8, textAlign: 'center' }}>
                        <div style={{ background: '#fff', borderRadius: 8, padding: '8px 4px', border: '1px solid #DBEAFE' }}>
                          <div style={{ fontSize: 14, fontWeight: 800, color: '#0284C7' }}>{rule1Count}</div>
                          <div style={{ fontSize: 9.5, fontWeight: 700, color: '#64748B' }}>Rule 1 (Range)</div>
                        </div>
                        <div style={{ background: '#fff', borderRadius: 8, padding: '8px 4px', border: '1px solid #DBEAFE' }}>
                          <div style={{ fontSize: 14, fontWeight: 800, color: '#059669' }}>{rule2Count}</div>
                          <div style={{ fontSize: 9.5, fontWeight: 700, color: '#64748B' }}>Rule 2 (Visual)</div>
                        </div>
                        <div style={{ background: '#fff', borderRadius: 8, padding: '8px 4px', border: '1px solid #DBEAFE' }}>
                          <div style={{ fontSize: 14, fontWeight: 800, color: '#D97706' }}>{rule3Count}</div>
                          <div style={{ fontSize: 9.5, fontWeight: 700, color: '#64748B' }}>Rule 3 (Limit)</div>
                        </div>
                        <div style={{ background: '#fff', borderRadius: 8, padding: '8px 4px', border: '1px solid #DBEAFE' }}>
                          <div style={{ fontSize: 14, fontWeight: 800, color: '#DC2626' }}>{criticalCount}</div>
                          <div style={{ fontSize: 9.5, fontWeight: 700, color: '#64748B' }}>◑ Critical</div>
                        </div>
                      </div>

                      {/* Category Breakdown Bar */}
                      <div style={{ display: 'flex', gap: 8, fontSize: 11, fontWeight: 700 }}>
                        <div style={{ flex: 1, background: '#DBEAFE', color: '#1E40AF', padding: '6px 10px', borderRadius: 6, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                          <span>Product Parameters</span>
                          <span style={{ background: '#1E40AF', color: '#fff', padding: '1px 8px', borderRadius: 10, fontSize: 10, fontWeight: 800 }}>{parameters.length}</span>
                        </div>
                        <div style={{ flex: 1, background: '#F3E8FF', color: '#6B21A8', padding: '6px 10px', borderRadius: 6, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                          <span>Process Parameters</span>
                          <span style={{ background: '#6B21A8', color: '#fff', padding: '1px 8px', borderRadius: 10, fontSize: 10, fontWeight: 800 }}>{processParameters.length}</span>
                        </div>
                      </div>
                    </div>
                  );
                })()}

                {/* Mobile Targets Notification */}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: '#F0FDF4', borderRadius: 8, border: '1px solid #BBF7D0' }}>
                    <div style={{ fontSize: 11.5, color: '#166534' }}>
                      <strong>Operator Terminal:</strong> Automatically updates in-process inspection checklist.
                    </div>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: '#F0FDF4', borderRadius: 8, border: '1px solid #BBF7D0' }}>
                    <div style={{ fontSize: 11.5, color: '#166534' }}>
                      <strong>Quality Inspector Terminal:</strong> Ready for 1st Piece Inspection (FPI) verification.
                    </div>
                  </div>
                </div>
              </div>

              <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                <button
                  type="button"
                  className="btn btn-ghost"
                  disabled={isPublishing}
                  onClick={() => setShowPublishModal(false)}
                  style={{ borderRadius: 8, fontWeight: 600 }}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={isPublishing || parameters.length === 0}
                  onClick={handlePublishTemplate}
                  style={{
                    padding: '9px 20px', fontWeight: 600, borderRadius: 6, fontSize: 13,
                    background: '#0F172A',
                    color: '#fff', border: '1px solid #0F172A', cursor: isPublishing ? 'wait' : 'pointer',
                    boxShadow: '0 1px 2px rgba(0,0,0,0.05)',
                    display: 'flex', alignItems: 'center', gap: 8,
                  }}
                >
                  {isPublishing ? (
                    <>
                      <span className="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span>
                      <span>Broadcasting to Mobile...</span>
                    </>
                  ) : (
                    <>
                      <span>Confirm & Dispatch Now</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── Modal: Submit Template for Quality Review ── */}
        {showSubmitReviewModal && (
          <div className="modal-overlay" onClick={() => !isSubmittingReview && setShowSubmitReviewModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px' }}>
                <div>
                  <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <FileText size={18} />
                    <span>Submit for Quality Review</span>
                  </h3>
                  <p style={{ margin: 0, fontSize: 11.5, color: '#94A3B8' }}>Assign Reviewer & Approver for 3-Tier Sign-Off</p>
                </div>
                {!isSubmittingReview && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowSubmitReviewModal(false)}>×</button>
                )}
              </div>

              <form onSubmit={handleSubmitReview}>
                <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 16 }}>
                  {/* Scope Summary Box */}
                  <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 10, padding: '12px 16px', fontSize: 12 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                      <div><strong style={{ color: '#64748B' }}>Part:</strong> {selectedPart?.part_number}</div>
                      <div><strong style={{ color: '#64748B' }}>Operation:</strong> {selectedTemplate?.name || selectedTemplate?.inspection_type} (v{selectedTemplate?.version})</div>
                      <div><strong style={{ color: '#64748B' }}>Product Parameters:</strong> {parameters.length}</div>
                      <div><strong style={{ color: '#64748B' }}>Process Parameters:</strong> {processParameters.length}</div>
                    </div>
                  </div>

                  {/* Select Reviewer */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>
                      Assigned Reviewer (Quality Inspector / Supervisor)
                    </label>
                    <select
                      className="form-input"
                      value={submitReviewForm.assigned_reviewer}
                      onChange={(e) => setSubmitReviewForm({ ...submitReviewForm, assigned_reviewer: e.target.value })}
                      style={{ fontSize: 13 }}
                    >
                      <option value="">Select Quality Reviewer</option>
                      {eligibleSignoffUsers.map((u) => (
                        <option key={u.id} value={u.id}>
                          {u.first_name || u.last_name ? `${u.first_name} ${u.last_name}` : u.username} ({u.role_display || u.role})
                        </option>
                      ))}
                    </select>
                    <small style={{ color: '#0369A1', fontSize: 11, marginTop: 4, display: 'block', fontWeight: 600 }}>
                      An automated email and in-app notification will be dispatched to the selected reviewer.
                    </small>
                  </div>

                  {/* Select Approver */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>
                      Assigned Approver (Quality Head / Admin)
                    </label>
                    <select
                      className="form-input"
                      value={submitReviewForm.assigned_approver}
                      onChange={(e) => setSubmitReviewForm({ ...submitReviewForm, assigned_approver: e.target.value })}
                      style={{ fontSize: 13 }}
                    >
                      <option value="">Select Final Approver</option>
                      {eligibleSignoffUsers.map((u) => (
                        <option key={u.id} value={u.id}>
                          {u.first_name || u.last_name ? `${u.first_name} ${u.last_name}` : u.username} ({u.role_display || u.role})
                        </option>
                      ))}
                    </select>
                    <small style={{ color: '#0369A1', fontSize: 11, marginTop: 4, display: 'block', fontWeight: 600 }}>
                      An automated notification and advance email will be dispatched to the selected approver.
                    </small>
                  </div>

                  {/* Submission Notes */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>
                      Submission Remarks / Notes (Optional)
                    </label>
                    <textarea
                      rows={3}
                      className="form-input"
                      placeholder="e.g. Dimensions updated according to latest revision C drawing. Please verify."
                      value={submitReviewForm.notes}
                      onChange={(e) => setSubmitReviewForm({ ...submitReviewForm, notes: e.target.value })}
                      style={{ resize: 'vertical', fontSize: 12.5 }}
                    />
                  </div>
                </div>

                <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                  <button
                    type="button"
                    className="btn btn-ghost"
                    disabled={isSubmittingReview}
                    onClick={() => setShowSubmitReviewModal(false)}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    className="btn btn-primary"
                    disabled={isSubmittingReview || (parameters.length === 0 && processParameters.length === 0)}
                    style={{
                      background: '#2563EB',
                      border: '1px solid #1D4ED8',
                      borderRadius: 6,
                      display: 'flex', alignItems: 'center', gap: 6
                    }}
                  >
                    {isSubmittingReview ? 'Submitting...' : 'Confirm Submission'}
                  </button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* ── Modal: Review & Recommend / Reject ── */}
        {showReviewModal && (
          <div className="modal-overlay" onClick={() => !isProcessingReview && setShowReviewModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px' }}>
                <div>
                  <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Eye size={18} />
                    <span>Review Inspection Template</span>
                  </h3>
                  <p style={{ margin: 0, fontSize: 11.5, color: '#94A3B8' }}>Stage 2: Recommend for final approval or request revisions</p>
                </div>
                {!isProcessingReview && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowReviewModal(false)}>×</button>
                )}
              </div>

              <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 16 }}>
                {/* Summary */}
                <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 10, padding: '12px 16px', fontSize: 12 }}>
                  <div><strong>Operation:</strong> {selectedTemplate?.name || selectedTemplate?.inspection_type} · <strong>Part:</strong> {selectedPart?.part_number}</div>
                  <div style={{ marginTop: 4, color: '#64748B' }}>
                    Prepared by {selectedTemplate?.created_by_name || 'Creator'} · {parameters.length} Product + {processParameters.length} Process parameters
                  </div>
                </div>

                {/* Review Action Selection */}
                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 8, display: 'block' }}>
                    Review Decision *
                  </label>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div
                      onClick={() => setReviewActionForm({ ...reviewActionForm, action: 'recommend' })}
                      style={{
                        border: `2px solid ${reviewActionForm.action === 'recommend' ? '#10B981' : '#E2E8F0'}`,
                        background: reviewActionForm.action === 'recommend' ? '#F0FDF4' : '#FFFFFF',
                        borderRadius: 10,
                        padding: '12px 14px',
                        cursor: 'pointer',
                        textAlign: 'center',
                        transition: 'all 0.2s ease'
                      }}
                    >
                      <CheckCircle2 size={22} color="#059669" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 13, fontWeight: 800, color: reviewActionForm.action === 'recommend' ? '#15803D' : '#0F172A' }}>
                        Recommend
                      </div>
                      <div style={{ fontSize: 10.5, color: '#64748B', marginTop: 2 }}>
                        Approve parameters & send to Final Sign-off
                      </div>
                    </div>

                    <div
                      onClick={() => setReviewActionForm({ ...reviewActionForm, action: 'reject' })}
                      style={{
                        border: `2px solid ${reviewActionForm.action === 'reject' ? '#EF4444' : '#E2E8F0'}`,
                        background: reviewActionForm.action === 'reject' ? '#FEF2F2' : '#FFFFFF',
                        borderRadius: 10,
                        padding: '12px 14px',
                        cursor: 'pointer',
                        textAlign: 'center',
                        transition: 'all 0.2s ease'
                      }}
                    >
                      <X size={22} color="#DC2626" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 13, fontWeight: 800, color: reviewActionForm.action === 'reject' ? '#B91C1C' : '#0F172A' }}>
                        Request Changes
                      </div>
                      <div style={{ fontSize: 10.5, color: '#64748B', marginTop: 2 }}>
                        Reject and send back to draft
                      </div>
                    </div>
                  </div>
                </div>

                {/* Remarks textarea */}
                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>
                    {reviewActionForm.action === 'reject' ? 'Reason for Rejection *' : 'Review Remarks / Inspection Notes'}
                  </label>
                  <textarea
                    rows={3}
                    className="form-input"
                    placeholder={
                      reviewActionForm.action === 'reject'
                        ? 'Please specify what tolerances or parameters need correction...'
                        : 'e.g. Dimensions verified against drawing rev C. Recommended for final approval.'
                    }
                    value={reviewActionForm.comments}
                    onChange={(e) => setReviewActionForm({ ...reviewActionForm, comments: e.target.value })}
                    style={{ resize: 'vertical', fontSize: 12.5 }}
                  />
                </div>
              </div>

              <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                <button
                  type="button"
                  className="btn btn-ghost"
                  disabled={isProcessingReview}
                  onClick={() => setShowReviewModal(false)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={isProcessingReview || (reviewActionForm.action === 'reject' && !reviewActionForm.comments.trim())}
                  onClick={() => handleSubmitReviewAction(reviewActionForm.action)}
                  style={{
                    padding: '8px 20px',
                    borderRadius: 8,
                    fontWeight: 800,
                    fontSize: 13,
                    border: 'none',
                    cursor: 'pointer',
                    color: '#fff',
                    borderRadius: 6,
                    fontWeight: 600,
                    background: reviewActionForm.action === 'recommend' ? '#15803D' : '#DC2626'
                  }}
                >
                  {isProcessingReview ? 'Processing...' : reviewActionForm.action === 'recommend' ? 'Confirm & Recommend' : 'Reject & Return'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── Modal: Final Approve & Dispatch ── */}
        {showApproveModal && (
          <div className="modal-overlay" onClick={() => !isProcessingApprove && setShowApproveModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px' }}>
                <div>
                  <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Shield size={18} />
                    <span>Final Quality Sign-Off & Dispatch</span>
                  </h3>
                  <p style={{ margin: 0, fontSize: 11.5, color: '#94A3B8' }}>Stage 3: Authorize master parameters and broadcast to shop floor</p>
                </div>
                {!isProcessingApprove && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowApproveModal(false)}>×</button>
                )}
              </div>

              <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 16 }}>
                {/* Audit summary */}
                <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 10, padding: '12px 16px', fontSize: 12 }}>
                  <div><strong>Operation:</strong> {selectedTemplate?.name || selectedTemplate?.inspection_type} · <strong>Part:</strong> {selectedPart?.part_number}</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 8 }}>
                    <div><strong style={{ color: '#64748B' }}>1. Prepared By:</strong> {selectedTemplate?.created_by_name || 'Creator'}</div>
                    <div><strong style={{ color: '#64748B' }}>2. Reviewed By:</strong> {selectedTemplate?.reviewed_by_name || 'Reviewer'}</div>
                  </div>
                  {selectedTemplate?.review_comments && (
                    <div style={{ marginTop: 6, fontStyle: 'italic', color: '#334155' }}>
                      Reviewer Note: "{selectedTemplate.review_comments}"
                    </div>
                  )}
                </div>

                {/* Approve Decision Selection */}
                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 8, display: 'block' }}>
                    Approval Decision *
                  </label>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div
                      onClick={() => setApproveActionForm({ ...approveActionForm, action: 'approve' })}
                      style={{
                        border: `2px solid ${approveActionForm.action === 'approve' ? '#059669' : '#E2E8F0'}`,
                        background: approveActionForm.action === 'approve' ? '#ECFDF5' : '#FFFFFF',
                        borderRadius: 10,
                        padding: '12px 14px',
                        cursor: 'pointer',
                        textAlign: 'center',
                        transition: 'all 0.2s ease'
                      }}
                    >
                      <CheckCircle2 size={22} color="#059669" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 13, fontWeight: 800, color: approveActionForm.action === 'approve' ? '#047857' : '#0F172A' }}>
                        Approve & Publish
                      </div>
                      <div style={{ fontSize: 10.5, color: '#64748B', marginTop: 2 }}>
                        Authorize and dispatch to mobile shop floor
                      </div>
                    </div>

                    <div
                      onClick={() => setApproveActionForm({ ...approveActionForm, action: 'reject' })}
                      style={{
                        border: `2px solid ${approveActionForm.action === 'reject' ? '#EF4444' : '#E2E8F0'}`,
                        background: approveActionForm.action === 'reject' ? '#FEF2F2' : '#FFFFFF',
                        borderRadius: 10,
                        padding: '12px 14px',
                        cursor: 'pointer',
                        textAlign: 'center',
                        transition: 'all 0.2s ease'
                      }}
                    >
                      <X size={22} color="#DC2626" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 13, fontWeight: 800, color: approveActionForm.action === 'reject' ? '#B91C1C' : '#0F172A' }}>
                        Reject & Return
                      </div>
                      <div style={{ fontSize: 10.5, color: '#64748B', marginTop: 2 }}>
                        Send back for correction
                      </div>
                    </div>
                  </div>
                </div>

                {/* Approval Comments */}
                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>
                    {approveActionForm.action === 'reject' ? 'Reason for Rejection *' : 'Approval Comments / Sign-Off Remarks'}
                  </label>
                  <textarea
                    rows={3}
                    className="form-input"
                    placeholder={
                      approveActionForm.action === 'reject'
                        ? 'Please specify why this operation template is rejected...'
                        : 'e.g. Master parameters approved for production run. Authorized for mobile checklist.'
                    }
                    value={approveActionForm.comments}
                    onChange={(e) => setApproveActionForm({ ...approveActionForm, comments: e.target.value })}
                    style={{ resize: 'vertical', fontSize: 12.5 }}
                  />
                </div>
              </div>

              <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                <button
                  type="button"
                  className="btn btn-ghost"
                  disabled={isProcessingApprove}
                  onClick={() => setShowApproveModal(false)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={isProcessingApprove || (approveActionForm.action === 'reject' && !approveActionForm.comments.trim())}
                  onClick={() => handleSubmitApproveAction(approveActionForm.action)}
                  style={{
                    padding: '8px 20px',
                    borderRadius: 8,
                    fontWeight: 800,
                    fontSize: 13,
                    border: 'none',
                    cursor: 'pointer',
                    color: '#fff',
                    borderRadius: 6,
                    fontWeight: 600,
                    background: approveActionForm.action === 'approve' ? '#15803D' : '#DC2626'
                  }}
                >
                  {isProcessingApprove ? 'Processing...' : approveActionForm.action === 'approve' ? 'Authorize & Publish Now' : 'Reject & Return'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── Modal: Initiate Document Change Request (DCR - Form DKI/MR/F/05) ── */}
        {showDCRModal && (
          <div className="modal-overlay" onClick={() => !isSubmittingDCR && setShowDCRModal(false)}>
            <div className="modal-content" style={{ maxWidth: 580, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <FileText size={18} color="#38BDF8" />
                    <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC' }}>
                      Document Change Request (DCR)
                    </h3>
                    <span style={{ background: '#1E293B', border: '1px solid #334155', color: '#38BDF8', padding: '2px 8px', borderRadius: 6, fontSize: 10, fontWeight: 700 }}>
                      Form DKI/MR/F/05
                    </span>
                  </div>
                  <p style={{ margin: '4px 0 0 0', fontSize: 11.5, color: '#94A3B8' }}>
                    Engineering & Quality Change Governance for Approved Inspection Sheets
                  </p>
                </div>
                {!isSubmittingDCR && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowDCRModal(false)}>×</button>
                )}
              </div>

              <form onSubmit={handleSubmitDCR}>
                <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
                  {/* Context header */}
                  <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: '10px 14px', fontSize: 12 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6 }}>
                      <div><span style={{ color: '#64748B' }}>Part Number:</span> <strong>{selectedPart?.part_number}</strong></div>
                      <div><span style={{ color: '#64748B' }}>Operation:</span> <strong>{selectedTemplate?.name || selectedTemplate?.inspection_type} (v{selectedTemplate?.version})</strong></div>
                      <div><span style={{ color: '#64748B' }}>Status:</span> <strong style={{ color: '#15803D' }}>Approved & Active</strong></div>
                      <div><span style={{ color: '#64748B' }}>Doc Control:</span> <strong>DKI/MR/F/05</strong></div>
                    </div>
                  </div>

                  {/* Change Type Selection */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Change Type *</label>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                      {[
                        { id: 'modification', label: 'Modification', desc: 'Update limits/tol' },
                        { id: 'addition', label: 'Addition', desc: 'New parameter' },
                        { id: 'deletion', label: 'Deletion', desc: 'Remove parameter' }
                      ].map((t) => (
                        <div
                          key={t.id}
                          onClick={() => setDcrForm({ ...dcrForm, change_type: t.id })}
                          style={{
                            border: `2px solid ${dcrForm.change_type === t.id ? '#0284C7' : '#E2E8F0'}`,
                            background: dcrForm.change_type === t.id ? '#EFF6FF' : '#FFFFFF',
                            borderRadius: 8, padding: '10px', cursor: 'pointer', textAlign: 'center', transition: 'all 0.15s'
                          }}
                        >
                          <div style={{ fontSize: 12.5, fontWeight: 700, color: dcrForm.change_type === t.id ? '#0284C7' : '#0F172A' }}>{t.label}</div>
                          <div style={{ fontSize: 10, color: '#64748B', marginTop: 2 }}>{t.desc}</div>
                        </div>
                      ))}
                    </div>
                  </div>

                  {/* Target Parameter selection if modification or deletion */}
                  {dcrForm.change_type !== 'addition' ? (
                    <div>
                      <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Target Parameter to Change / Delete *</label>
                      <select
                        className="form-input"
                        value={dcrForm.target_param_id ? `${dcrForm.target_type}:${dcrForm.target_param_id}` : ''}
                        onChange={(e) => {
                          const val = e.target.value;
                          if (!val) {
                            setDcrForm({ ...dcrForm, target_param_id: '', parameter_code: '', parameter_name: '', current_specification: '' });
                            return;
                          }
                          const [type, id] = val.split(':');
                          const numericId = parseInt(id);
                          if (type === 'product') {
                            const found = parameters.find(p => p.id === numericId);
                            if (found) {
                              setDcrForm({
                                ...dcrForm,
                                target_type: 'product',
                                target_param_id: numericId,
                                parameter_code: found.parameter_code || `P${found.sequence_order}`,
                                parameter_name: found.parameter_name,
                                current_specification: `Nominal: ${found.nominal_value} ${found.unit}, Tol: +${found.upper_tolerance} / ${found.lower_tolerance} (${found.measurement_type})`,
                                proposed_specification: dcrForm.change_type === 'deletion' ? 'Parameter Deletion Requested' : dcrForm.proposed_specification
                              });
                            }
                          } else {
                            const found = processParameters.find(p => p.id === numericId);
                            if (found) {
                              setDcrForm({
                                ...dcrForm,
                                target_type: 'process',
                                target_param_id: numericId,
                                parameter_code: found.parameter_code || `PR${found.sequence_order}`,
                                parameter_name: found.parameter_name,
                                current_specification: found.specification || `Nominal: ${found.nominal_value} ${found.unit}, Tol: +${found.upper_tolerance} / ${found.lower_tolerance}`,
                                proposed_specification: dcrForm.change_type === 'deletion' ? 'Process Parameter Deletion Requested' : dcrForm.proposed_specification
                              });
                            }
                          }
                        }}
                        required
                        style={{ fontSize: 13 }}
                      >
                        <option value="">Select Existing Parameter</option>
                        <optgroup label="Product Parameters">
                          {parameters.map(p => (
                            <option key={`product:${p.id}`} value={`product:${p.id}`}>
                              [P{p.sequence_order}] {p.parameter_name} ({p.nominal_value} {p.unit})
                            </option>
                          ))}
                        </optgroup>
                        <optgroup label="Process Parameters">
                          {processParameters.map(pp => (
                            <option key={`process:${pp.id}`} value={`process:${pp.id}`}>
                              [PR{pp.sequence_order}] {pp.parameter_name}
                            </option>
                          ))}
                        </optgroup>
                      </select>
                    </div>
                  ) : (
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 10 }}>
                      <div>
                        <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Parameter Category *</label>
                        <select
                          className="form-input"
                          value={dcrForm.target_type}
                          onChange={(e) => setDcrForm({ ...dcrForm, target_type: e.target.value })}
                          style={{ fontSize: 12.5 }}
                        >
                          <option value="product">Product Parameter</option>
                          <option value="process">Process Parameter</option>
                        </select>
                      </div>
                      <div>
                        <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>New Parameter Name *</label>
                        <input
                          type="text"
                          className="form-input"
                          placeholder="e.g. Outer Diameter Step 2"
                          value={dcrForm.parameter_name}
                          onChange={(e) => setDcrForm({ ...dcrForm, parameter_name: e.target.value })}
                          required
                          style={{ fontSize: 12.5 }}
                        />
                      </div>
                    </div>
                  )}

                  {/* Current Specification (Read Only) */}
                  {dcrForm.change_type !== 'addition' && (
                    <div>
                      <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Current Approved Specification (Read Only)</label>
                      <input
                        type="text"
                        className="form-input"
                        value={formatSpecification(dcrForm.current_specification)}
                        readOnly
                        style={{ background: '#F1F5F9', color: '#475569', fontSize: 12 }}
                      />
                    </div>
                  )}

                  {/* Proposed Specification */}
                  {dcrForm.change_type !== 'deletion' && (
                    <div>
                      <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Proposed Specification & Tolerance Details *</label>
                      <textarea
                        rows={2}
                        className="form-input"
                        placeholder="e.g. Nominal: 12.50 mm, Upper Tol: +0.05, Lower Tol: -0.05, Technique: Micrometer"
                        value={dcrForm.proposed_specification}
                        onChange={(e) => setDcrForm({ ...dcrForm, proposed_specification: e.target.value })}
                        required
                        style={{ fontSize: 12.5, resize: 'vertical' }}
                      />
                    </div>
                  )}

                  {/* Basis for Change / Reason */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Basis for Change / Engineering Reason *</label>
                    <textarea
                      rows={2}
                      className="form-input"
                      placeholder="e.g. Customer Engineering Change Notice (ECN-2026-88), tool wear compensation, or drawing revision C."
                      value={dcrForm.basis_for_change}
                      onChange={(e) => setDcrForm({ ...dcrForm, basis_for_change: e.target.value })}
                      required
                      style={{ fontSize: 12.5, resize: 'vertical' }}
                    />
                  </div>

                  {/* Reviewer & Approver assignment */}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div>
                      <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Quality Reviewer *</label>
                      <select
                        className="form-input"
                        value={dcrForm.assigned_reviewer}
                        onChange={(e) => setDcrForm({ ...dcrForm, assigned_reviewer: e.target.value })}
                        required
                        style={{ fontSize: 12.5 }}
                      >
                        <option value="">Select Reviewer</option>
                        {eligibleSignoffUsers.map((u) => (
                          <option key={u.id} value={u.id}>
                            {u.first_name || u.last_name ? `${u.first_name} ${u.last_name}` : u.username} ({u.role_display || u.role})
                          </option>
                        ))}
                      </select>
                    </div>
                    <div>
                      <label className="form-label" style={{ fontWeight: 700, fontSize: 12 }}>Quality Approver *</label>
                      <select
                        className="form-input"
                        value={dcrForm.assigned_approver}
                        onChange={(e) => setDcrForm({ ...dcrForm, assigned_approver: e.target.value })}
                        required
                        style={{ fontSize: 12.5 }}
                      >
                        <option value="">Select Approver</option>
                        {eligibleSignoffUsers.map((u) => (
                          <option key={u.id} value={u.id}>
                            {u.first_name || u.last_name ? `${u.first_name} ${u.last_name}` : u.username} ({u.role_display || u.role})
                          </option>
                        ))}
                      </select>
                    </div>
                  </div>
                </div>

                <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                  <button type="button" className="btn btn-ghost" disabled={isSubmittingDCR} onClick={() => setShowDCRModal(false)}>
                    Cancel
                  </button>
                  <button
                    type="submit"
                    className="btn btn-primary"
                    disabled={isSubmittingDCR || !dcrForm.basis_for_change.trim()}
                    style={{ background: '#0F172A', color: '#fff', display: 'flex', alignItems: 'center', gap: 6 }}
                  >
                    {isSubmittingDCR ? 'Submitting DCR...' : 'Submit DCR (Form DKI/MR/F/05)'}
                  </button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* ── Modal: Review DCR (Form DKI/MR/F/05) ── */}
        {showDCRReviewModal && selectedDCR && (
          <div className="modal-overlay" onClick={() => !isProcessingDCRReview && setShowDCRReviewModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Eye size={18} /> Review Document Change Request
                  </h3>
                  <p style={{ margin: 0, fontSize: 11.5, color: '#94A3B8' }}>
                    {selectedDCR.dcr_number} · Form DKI/MR/F/05
                  </p>
                </div>
                {!isProcessingDCRReview && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowDCRReviewModal(false)}>×</button>
                )}
              </div>

              <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
                <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: '12px 14px', fontSize: 12 }}>
                  <div style={{ marginBottom: 4 }}><strong>Parameter:</strong> {selectedDCR.parameter_code ? `[${selectedDCR.parameter_code}] ` : ''}{selectedDCR.parameter_name}</div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Change Type:</span> <strong style={{ textTransform: 'uppercase' }}>{selectedDCR.change_type}</strong></div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Current Spec:</span> {formatSpecification(selectedDCR.current_specification)}</div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Proposed Spec:</span> <strong style={{ color: '#0F172A' }}>{formatSpecification(selectedDCR.proposed_specification)}</strong></div>
                  <div><span style={{ color: '#64748B' }}>Basis for Change:</span> {selectedDCR.basis_for_change}</div>
                </div>

                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 8, display: 'block' }}>
                    Review Decision *
                  </label>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div
                      onClick={() => setDcrReviewForm({ ...dcrReviewForm, action: 'recommend' })}
                      style={{
                        border: `2px solid ${dcrReviewForm.action === 'recommend' ? '#10B981' : '#E2E8F0'}`,
                        background: dcrReviewForm.action === 'recommend' ? '#F0FDF4' : '#FFFFFF',
                        borderRadius: 8, padding: '10px', cursor: 'pointer', textAlign: 'center'
                      }}
                    >
                      <CheckCircle2 size={20} color="#059669" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 12.5, fontWeight: 800, color: dcrReviewForm.action === 'recommend' ? '#15803D' : '#0F172A' }}>Recommend</div>
                      <div style={{ fontSize: 10, color: '#64748B' }}>Forward to Approver</div>
                    </div>
                    <div
                      onClick={() => setDcrReviewForm({ ...dcrReviewForm, action: 'reject' })}
                      style={{
                        border: `2px solid ${dcrReviewForm.action === 'reject' ? '#EF4444' : '#E2E8F0'}`,
                        background: dcrReviewForm.action === 'reject' ? '#FEF2F2' : '#FFFFFF',
                        borderRadius: 8, padding: '10px', cursor: 'pointer', textAlign: 'center'
                      }}
                    >
                      <X size={20} color="#DC2626" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 12.5, fontWeight: 800, color: dcrReviewForm.action === 'reject' ? '#B91C1C' : '#0F172A' }}>Reject</div>
                      <div style={{ fontSize: 10, color: '#64748B' }}>Deny change request</div>
                    </div>
                  </div>
                </div>

                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>Review Remarks *</label>
                  <textarea
                    rows={3}
                    className="form-input"
                    placeholder={dcrReviewForm.action === 'reject' ? 'State reason for rejecting change...' : 'State review remarks or verification of drawing / instrument...'}
                    value={dcrReviewForm.remarks}
                    onChange={(e) => setDcrReviewForm({ ...dcrReviewForm, remarks: e.target.value })}
                    style={{ fontSize: 12.5, resize: 'vertical' }}
                  />
                </div>
              </div>

              <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                <button type="button" className="btn btn-ghost" disabled={isProcessingDCRReview} onClick={() => setShowDCRReviewModal(false)}>
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={isProcessingDCRReview || (dcrReviewForm.action === 'reject' && !dcrReviewForm.remarks.trim())}
                  onClick={() => handleReviewDCRSubmit(dcrReviewForm.action)}
                  style={{
                    padding: '8px 20px', borderRadius: 8, fontWeight: 800, fontSize: 13, border: 'none', cursor: 'pointer', color: '#fff',
                    background: dcrReviewForm.action === 'recommend' ? '#059669' : '#DC2626'
                  }}
                >
                  {isProcessingDCRReview ? 'Processing...' : dcrReviewForm.action === 'recommend' ? 'Confirm & Recommend' : 'Reject DCR'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── Modal: Approve DCR (Form DKI/MR/F/05) ── */}
        {showDCRApproveModal && selectedDCR && (
          <div className="modal-overlay" onClick={() => !isProcessingDCRApprove && setShowDCRApproveModal(false)}>
            <div className="modal-content" style={{ maxWidth: 520, borderRadius: 16, overflow: 'hidden' }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header" style={{ background: '#0F172A', color: '#fff', padding: '16px 20px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <h3 style={{ margin: 0, fontSize: 16, fontWeight: 800, color: '#F8FAFC', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Shield size={18} /> Final Sign-Off & Implement DCR
                  </h3>
                  <p style={{ margin: 0, fontSize: 11.5, color: '#94A3B8' }}>
                    {selectedDCR.dcr_number} · Approving will automatically update parameter specifications
                  </p>
                </div>
                {!isProcessingDCRApprove && (
                  <button type="button" className="btn-close" style={{ color: '#fff' }} onClick={() => setShowDCRApproveModal(false)}>×</button>
                )}
              </div>

              <div className="modal-body" style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
                <div style={{ background: '#F8FAFC', border: '1px solid #E2E8F0', borderRadius: 8, padding: '12px 14px', fontSize: 12 }}>
                  <div style={{ marginBottom: 4 }}><strong>Parameter:</strong> {selectedDCR.parameter_code ? `[${selectedDCR.parameter_code}] ` : ''}{selectedDCR.parameter_name}</div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Change Type:</span> <strong style={{ textTransform: 'uppercase' }}>{selectedDCR.change_type}</strong></div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Proposed Specification:</span> <strong style={{ color: '#047857' }}>{formatSpecification(selectedDCR.proposed_specification)}</strong></div>
                  <div style={{ marginBottom: 4 }}><span style={{ color: '#64748B' }}>Reviewer Remarks:</span> {selectedDCR.review_remarks || 'None'}</div>
                </div>

                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 8, display: 'block' }}>
                    Approval Decision *
                  </label>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <div
                      onClick={() => setDcrApproveForm({ ...dcrApproveForm, action: 'approve' })}
                      style={{
                        border: `2px solid ${dcrApproveForm.action === 'approve' ? '#059669' : '#E2E8F0'}`,
                        background: dcrApproveForm.action === 'approve' ? '#ECFDF5' : '#FFFFFF',
                        borderRadius: 8, padding: '10px', cursor: 'pointer', textAlign: 'center'
                      }}
                    >
                      <CheckCircle2 size={20} color="#059669" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 12.5, fontWeight: 800, color: dcrApproveForm.action === 'approve' ? '#047857' : '#0F172A' }}>Authorize & Implement</div>
                      <div style={{ fontSize: 10, color: '#64748B' }}>Apply changes to live template</div>
                    </div>
                    <div
                      onClick={() => setDcrApproveForm({ ...dcrApproveForm, action: 'reject' })}
                      style={{
                        border: `2px solid ${dcrApproveForm.action === 'reject' ? '#EF4444' : '#E2E8F0'}`,
                        background: dcrApproveForm.action === 'reject' ? '#FEF2F2' : '#FFFFFF',
                        borderRadius: 8, padding: '10px', cursor: 'pointer', textAlign: 'center'
                      }}
                    >
                      <X size={20} color="#DC2626" style={{ margin: '0 auto 4px auto' }} />
                      <div style={{ fontSize: 12.5, fontWeight: 800, color: dcrApproveForm.action === 'reject' ? '#B91C1C' : '#0F172A' }}>Reject</div>
                      <div style={{ fontSize: 10, color: '#64748B' }}>Deny change request</div>
                    </div>
                  </div>
                </div>

                <div>
                  <label className="form-label" style={{ fontWeight: 700, fontSize: 12.5 }}>Approval Comments *</label>
                  <textarea
                    rows={3}
                    className="form-input"
                    placeholder={dcrApproveForm.action === 'reject' ? 'State reason for rejection...' : 'State approval comments or authorization reference...'}
                    value={dcrApproveForm.remarks}
                    onChange={(e) => setDcrApproveForm({ ...dcrApproveForm, remarks: e.target.value })}
                    style={{ fontSize: 12.5, resize: 'vertical' }}
                  />
                </div>
              </div>

              <div className="modal-footer" style={{ padding: '14px 20px', background: '#F8FAFC', borderTop: '1px solid #E2E8F0', display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
                <button type="button" className="btn btn-ghost" disabled={isProcessingDCRApprove} onClick={() => setShowDCRApproveModal(false)}>
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={isProcessingDCRApprove || (dcrApproveForm.action === 'reject' && !dcrApproveForm.remarks.trim())}
                  onClick={() => handleApproveDCRSubmit(dcrApproveForm.action)}
                  style={{
                    padding: '8px 20px', borderRadius: 8, fontWeight: 800, fontSize: 13, border: 'none', cursor: 'pointer', color: '#fff',
                    background: dcrApproveForm.action === 'approve' ? '#059669' : '#DC2626'
                  }}
                >
                  {isProcessingDCRApprove ? 'Processing...' : dcrApproveForm.action === 'approve' ? 'Authorize & Implement' : 'Reject DCR'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Modal: Add / Edit Process Parameter */}
        {showProcessParamModal && selectedTemplate && (
          <div className="modal-overlay" onClick={() => setShowProcessParamModal(false)}>
            <div className="modal-content" style={{ maxWidth: 540 }} onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <h3>{editingProcessParam ? `Edit Process Parameter Rule` : `Add Process Parameter Rule to [${selectedTemplate?.inspection_type?.toUpperCase()}]`}</h3>
                <button type="button" className="btn-close" onClick={() => setShowProcessParamModal(false)}>×</button>
              </div>
              <form onSubmit={handleSaveProcessParam}>
                <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  
                  {/* 3 SPECIFICATION RULES SELECTOR */}
                  <div>
                    <label className="form-label" style={{ fontWeight: 'bold', marginBottom: 6, display: 'block' }}>
                      Select Quality Inspection Rule *
                    </label>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                      <button
                        type="button"
                        className={`btn btn-sm ${processRuleMode === 'rule1' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: processRuleMode === 'rule1' ? '2px solid #38BDF8' : '1px solid #334155' }}
                        onClick={() => selectProcessRuleMode('rule1')}
                      >
                        Rule 1: Range (&gt; Limit &lt;)
                      </button>
                      <button
                        type="button"
                        className={`btn btn-sm ${processRuleMode === 'rule2' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: processRuleMode === 'rule2' ? '2px solid #10B981' : '1px solid #334155' }}
                        onClick={() => selectProcessRuleMode('rule2')}
                      >
                        Rule 2: Visual (YES/NO)
                      </button>
                      <button
                        type="button"
                        className={`btn btn-sm ${processRuleMode === 'rule3' ? 'btn-primary' : 'btn-ghost'}`}
                        style={{ padding: '8px 4px', fontSize: 11, fontWeight: 'bold', border: processRuleMode === 'rule3' ? '2px solid #F59E0B' : '1px solid #334155' }}
                        onClick={() => selectProcessRuleMode('rule3')}
                      >
                        Rule 3: Limit (&le; or &ge;)
                      </button>
                    </div>
                  </div>

                  <div>
                    <label className="form-label">Parameter Name *</label>
                    <input
                      type="text"
                      className="form-input"
                      placeholder={
                        processRuleMode === 'rule1' ? 'e.g. RPM, Feed Rate, Pressure' :
                        processRuleMode === 'rule2' ? 'e.g. Chamfer & Deburring Check' : 'e.g. Max Temperature (Ra/°C)'
                      }
                      value={processParamForm.parameter_name}
                      onChange={(e) => setProcessParamForm({ ...processParamForm, parameter_name: e.target.value })}
                      required
                    />
                  </div>

                  {/* RULE 1 FIELDS */}
                  {processRuleMode === 'rule1' && (
                    <>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
                        <div>
                          <label className="form-label">Nominal Target *</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={processParamForm.nominal_value}
                            onChange={(e) => setProcessParamForm({ ...processParamForm, nominal_value: e.target.value })}
                            required
                          />
                        </div>
                        <div>
                          <label className="form-label">Upper Tol (+)</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={processParamForm.upper_tolerance}
                            onChange={(e) => setProcessParamForm({ ...processParamForm, upper_tolerance: e.target.value })}
                            required
                          />
                        </div>
                        <div>
                          <label className="form-label">Lower Tol (-)</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={processParamForm.lower_tolerance}
                            onChange={(e) => setProcessParamForm({ ...processParamForm, lower_tolerance: e.target.value })}
                            required
                          />
                        </div>
                      </div>
                      <div style={{ background: '#0F172A', padding: 10, borderRadius: 6, fontSize: 13, color: '#38BDF8', fontWeight: 'bold' }}>
                        Rule 1 Range: [{( (parseFloat(processParamForm.nominal_value) || 0) + (parseFloat(processParamForm.lower_tolerance) || 0) ).toFixed(4)} {processParamForm.unit}] to [{ ( (parseFloat(processParamForm.nominal_value) || 0) + Math.abs(parseFloat(processParamForm.upper_tolerance) || 0) ).toFixed(4)} {processParamForm.unit}]
                      </div>
                    </>
                  )}

                  {/* RULE 2 FIELDS */}
                  {processRuleMode === 'rule2' && (
                    <div>
                      <label className="form-label">Master Value / Visual Specification *</label>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="e.g. 0.5 x 45° Chamfer, No burrs, Surface smooth"
                        value={processParamForm.nominal_value || ''}
                        onChange={(e) => setProcessParamForm({ ...processParamForm, nominal_value: e.target.value })}
                        required
                      />
                      <div style={{ marginTop: 6, fontSize: 11, color: '#64748B' }}>
                        Inspector sees this value and records <strong>YES (Pass)</strong> or <strong>NO (Fail)</strong>
                      </div>
                    </div>
                  )}

                  {/* RULE 3 FIELDS */}
                  {processRuleMode === 'rule3' && (
                    <>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                        <div>
                          <label className="form-label">Threshold Type</label>
                          <select
                            className="form-select"
                            value={processParamForm.measurement_type}
                            onChange={(e) => setProcessParamForm({ ...processParamForm, measurement_type: e.target.value })}
                          >
                            <option value="max_limit">≤ Maximum Limit (e.g. ≤ 1200 RPM)</option>
                            <option value="min_limit">≥ Minimum Limit (e.g. ≥ 500 RPM)</option>
                            <option value="surface">≤ Surface Finish (Ra)</option>
                          </select>
                        </div>
                        <div>
                          <label className="form-label">Threshold Value *</label>
                          <input
                            type="number"
                            step="any"
                            className="form-input"
                            value={processParamForm.nominal_value}
                            onChange={(e) => setProcessParamForm({
                              ...processParamForm,
                              nominal_value: e.target.value,
                              upper_tolerance: '0.00',
                              lower_tolerance: '0.00',
                            })}
                            required
                          />
                        </div>
                      </div>
                      <div style={{ background: '#0F172A', padding: 10, borderRadius: 6, fontSize: 13, color: '#F59E0B', fontWeight: 'bold' }}>
                        Rule 3 Threshold: {processParamForm.measurement_type === 'min_limit' ? `≥ ${(parseFloat(processParamForm.nominal_value) || 0).toFixed(4)} ${processParamForm.unit}` : `≤ ${(parseFloat(processParamForm.nominal_value) || 0).toFixed(4)} ${processParamForm.unit}`}
                      </div>
                    </>
                  )}

                  {/* Unit + Type row */}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                    <div>
                      <label className="form-label">Unit</label>
                      <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap', marginBottom: 6 }}>
                        {['mm', '°', 'R', 'φ', 'µm', 'Ra', 'mm/rev', 'inch'].map((u) => {
                          const isSelected = processParamForm.unit === u;
                          return (
                            <button
                              key={u}
                              type="button"
                              onClick={() => setProcessParamForm({ ...processParamForm, unit: u })}
                              style={{
                                padding: '4px 10px', fontSize: 12, fontWeight: 700,
                                borderRadius: 16, border: '1px solid',
                                cursor: 'pointer', transition: 'all 0.15s ease',
                                background: isSelected ? '#0F172A' : '#F8FAFC',
                                color: isSelected ? '#FFFFFF' : '#475569',
                                borderColor: isSelected ? '#0F172A' : '#CBD5E1',
                                boxShadow: isSelected ? '0 1px 3px rgba(0,0,0,0.15)' : 'none',
                              }}
                            >{u}</button>
                          );
                        })}
                      </div>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="Custom unit if not listed above..."
                        value={processParamForm.unit}
                        onChange={(e) => setProcessParamForm({ ...processParamForm, unit: e.target.value })}
                        style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                      />
                    </div>
                    <div>
                      <label className="form-label">Measurement Type Code</label>
                      <input
                        type="text"
                        className="form-input"
                        value={processParamForm.measurement_type}
                        readOnly
                        style={{ opacity: 0.75, textTransform: 'uppercase', background: '#F1F5F9', border: '1px solid #CBD5E1', color: '#475569', borderRadius: 8, padding: '9px 12px', fontSize: 13, width: '100%' }}
                      />
                    </div>
                  </div>

                  {/* ── CONTROL PLAN COLUMNS ──────────────────── */}
                  <div style={{ borderTop: '1.5px solid #E2E8F0', paddingTop: 14 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: '#0284C7', textTransform: 'uppercase', letterSpacing: '0.8px', marginBottom: 10 }}>
                      Control Plan Details
                    </div>

                    {/* Measurement Technique */}
                    <div style={{ marginBottom: 12 }}>
                      <label className="form-label" style={{ marginBottom: 4 }}>Evaluation / Measurement Technique</label>
                      <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap', marginBottom: 6 }}>
                        {['DEPTH VERNIER', 'VERNIER CALIPER', 'VISUALLY', 'PLUGE GAUGE', 'PROFILE PROJECTOR', 'COMPARE WITH MASTER', 'HEIGHT GAUGE', 'MICROMETER'].map((t) => {
                          const isSel = processParamForm.measurement_technique === t;
                          return (
                            <button
                              key={t}
                              type="button"
                              onClick={() => setProcessParamForm({ ...processParamForm, measurement_technique: t })}
                              style={{
                                padding: '4px 9px', fontSize: 11, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                background: isSel ? '#0284C7' : '#F8FAFC',
                                border: isSel ? '1px solid #0284C7' : '1px solid #CBD5E1',
                                color: isSel ? '#FFFFFF' : '#475569',
                                transition: 'all 0.15s ease',
                              }}
                            >{t}</button>
                          );
                        })}
                      </div>
                      <input
                        type="text"
                        className="form-input"
                        placeholder="Or custom instrument..."
                        value={processParamForm.measurement_technique}
                        onChange={(e) => setProcessParamForm({ ...processParamForm, measurement_technique: e.target.value })}
                        style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                      />
                    </div>

                    {/* Sample Size + Control Method in 2 cols */}
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                      <div>
                        <label className="form-label" style={{ marginBottom: 4 }}>Sample Size / Frequency</label>
                        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 6 }}>
                          {['5NOS/SHIFT', '100%', 'LAYOUT INSPECTION', '1st PC/SHIFT'].map((s) => {
                            const isSel = processParamForm.sample_size === s;
                            return (
                              <button
                                key={s}
                                type="button"
                                onClick={() => setProcessParamForm({ ...processParamForm, sample_size: s })}
                                style={{
                                  padding: '3px 8px', fontSize: 10.5, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                  background: isSel ? '#059669' : '#F8FAFC',
                                  border: isSel ? '1px solid #059669' : '1px solid #CBD5E1',
                                  color: isSel ? '#FFFFFF' : '#475569',
                                  transition: 'all 0.15s ease',
                                }}
                              >{s}</button>
                            );
                          })}
                        </div>
                        <input
                          type="text"
                          className="form-input"
                          placeholder="e.g. 5NOS/SHIFT"
                          value={processParamForm.sample_size}
                          onChange={(e) => setProcessParamForm({ ...processParamForm, sample_size: e.target.value })}
                          style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                        />
                      </div>
                      <div>
                        <label className="form-label" style={{ marginBottom: 4 }}>Control Method</label>
                        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 6 }}>
                          {['1st PIECE & INPROCESS INSP.', 'LAYOUT INSPECTION'].map((c) => {
                            const isSel = processParamForm.control_method === c;
                            return (
                              <button
                                key={c}
                                type="button"
                                onClick={() => setProcessParamForm({ ...processParamForm, control_method: c })}
                                style={{
                                  padding: '3px 8px', fontSize: 10.5, fontWeight: isSel ? 700 : 500, borderRadius: 6, cursor: 'pointer',
                                  background: isSel ? '#7C3AED' : '#F8FAFC',
                                  border: isSel ? '1px solid #7C3AED' : '1px solid #CBD5E1',
                                  color: isSel ? '#FFFFFF' : '#475569',
                                  transition: 'all 0.15s ease',
                                }}
                              >{c}</button>
                            );
                          })}
                        </div>
                        <input
                          type="text"
                          className="form-input"
                          placeholder="e.g. 1st PIECE & INPROCESS INSP."
                          value={processParamForm.control_method}
                          onChange={(e) => setProcessParamForm({ ...processParamForm, control_method: e.target.value })}
                          style={{ background: '#fff', border: '1px solid #CBD5E1', color: '#1E293B', borderRadius: 8, padding: '7px 10px', fontSize: 12, width: '100%', outline: 'none', boxSizing: 'border-box' }}
                        />
                      </div>
                    </div>
                  </div>
                </div>

                <div className="modal-footer">
                  <button type="button" className="btn btn-ghost" onClick={() => setShowProcessParamModal(false)}>Cancel</button>
                  <button type="submit" className="btn btn-primary">{editingProcessParam ? 'Save Changes' : 'Add Process Parameter Rule'}</button>
                </div>
              </form>
            </div>
          </div>
        )}
          </>
        )}
      </div>
    </>
  );
}
