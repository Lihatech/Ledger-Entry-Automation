import React, { useState, useEffect } from 'react';
import {
  X, Download, ExternalLink, FileText, AlertCircle,
  Maximize2, Minimize2, Edit3, Calendar, Tag, CheckCircle, Shield, RefreshCw, AlertTriangle, Printer
} from 'lucide-react';
import { useAuth } from '../../context/AuthContext';
import { submitForReview, approveDocument, rejectDocument, getDownloadUrl, downloadDocument } from '../../api/documentControl';

const LEVEL_COLORS = {
  L1: { bg: '#f5f3ff', color: '#7c3aed', border: '#ddd6fe', label: 'L1 : Quality Manual' },
  L2: { bg: '#eff6ff', color: '#2563eb', border: '#bfdbfe', label: 'L2 : SOP' },
  L3: { bg: '#ecfdf5', color: '#059669', border: '#a7f3d0', label: 'L3 : Work Instruction' },
  L4: { bg: '#fffbeb', color: '#d97706', border: '#fde68a', label: 'L4 : Form / Record' },
};

export default function DocumentViewerModal({ doc, onClose, onRequestDCR, canRequestDCR, onUpdate }) {
  const { user } = useAuth();
  const [currentDoc, setCurrentDoc] = useState(doc);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [iframeLoading, setIframeLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [showRejectModal, setShowRejectModal] = useState(false);
  const [rejectComment, setRejectComment] = useState('');
  const [rejectError, setRejectError] = useState('');
  const [actionSuccessMsg, setActionSuccessMsg] = useState('');

  useEffect(() => {
    setCurrentDoc(doc);
    setActionSuccessMsg('');
  }, [doc]);

  if (!currentDoc) return null;

  const fileName = (currentDoc.file_name || '').toLowerCase();
  const fileType = (currentDoc.file_type || '').toLowerCase();

  const isPdf = fileName.endsWith('.pdf') || fileType.includes('pdf');
  const isImage = fileType.startsWith('image/') || /\.(png|jpe?g|webp|gif|svg)$/i.test(fileName);
  const isOfficeDoc = /\.(pptx?|docx?|xlsx?|rtf|csv|odt|ods|odp)$/i.test(fileName) ||
    fileType.includes('officedocument') ||
    fileType.includes('word') ||
    fileType.includes('presentation') ||
    fileType.includes('powerpoint') ||
    fileType.includes('spreadsheet') ||
    fileType.includes('excel');

  const rawDocumentUrl = currentDoc.delivery_url || currentDoc.cloudinary_url;
  // Ensure documentUrl is always HTTPS to prevent mixed content blocking in iframes
  const documentUrl = rawDocumentUrl ? rawDocumentUrl.replace(/^http:\/\//i, 'https://') : null;

  const levelInfo = LEVEL_COLORS[currentDoc.doc_level] || LEVEL_COLORS.L2;

  // Workflow Sign-off and Action Permissions
  const userRole = user?.role || '';
  const isManager = user?.is_superuser || userRole === 'admin';
  const isOwner = user && String(currentDoc.uploaded_by) === String(user.id);
  const myPerms = currentDoc.my_permissions || {};

  const canPreviewDoc = isManager || isOwner || Boolean(myPerms.can_preview);
  const canDownloadDoc = isManager || isOwner || Boolean(myPerms.can_download);
  const canPrintDoc = (isManager || isOwner || Boolean(myPerms.can_print)) && canPreviewDoc;

  // Resolve embed URL based on file type (automatic single universal viewer)
  const getEmbedUrl = () => {
    if (!documentUrl || !canPreviewDoc) return null;
    if (isPdf) {
      const showToolbar = (canPrintDoc || canDownloadDoc) ? 1 : 0;
      return `${documentUrl}#toolbar=${showToolbar}&navpanes=0`;
    }
    if (isOfficeDoc) {
      return `https://view.officeapps.live.com/op/embed.aspx?src=${encodeURIComponent(documentUrl)}`;
    }
    // Fallback for other document types
    return `https://view.officeapps.live.com/op/embed.aspx?src=${encodeURIComponent(documentUrl)}`;
  };

  const embedUrl = getEmbedUrl();


  // Workflow Sign-off Permissions
  const isReviewAlreadyDone = Boolean(currentDoc.reviewed_at || currentDoc.status === 'awaiting_approval' || currentDoc.status === 'approved');
  const isReviewer = user && (user.id === currentDoc.reviewed_by || ['admin', 'supervisor'].includes(userRole));
  const isApprover = user && (user.id === currentDoc.approved_by || userRole === 'admin');

  // Review is strictly visible ONLY before review is done
  const canReview = isReviewer && currentDoc.status === 'under_review' && !isReviewAlreadyDone;
  // Approval is available only after review has completed, including for admins.
  const canApprove = isApprover && currentDoc.status === 'awaiting_approval' && Boolean(currentDoc.reviewed_at);
  const canReject = (isReviewer || isApprover) && ['under_review', 'awaiting_approval'].includes(currentDoc.status);

  const handleReview = async () => {
    setActionLoading(true);
    try {
      const res = await submitForReview(currentDoc.id);
      const updatedDoc = res.data?.document;
      const userDisplayName = (user?.first_name || user?.last_name) ? `${user.first_name} ${user.last_name}`.trim() : user?.username;
      setCurrentDoc(prev => ({
        ...prev,
        ...(updatedDoc || {}),
        status: 'awaiting_approval',
        reviewed_at: updatedDoc?.reviewed_at || new Date().toISOString(),
        reviewed_by_name: prev.reviewed_by_name || userDisplayName
      }));
      setActionSuccessMsg('Reviewed successfully! Submitted for management approval.');
      if (onUpdate) onUpdate();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to submit review.');
    } finally {
      setActionLoading(false);
    }
  };

  const handleApprove = async () => {
    setActionLoading(true);
    try {
      const res = await approveDocument(currentDoc.id);
      const updatedDoc = res.data?.document;
      const userDisplayName = (user?.first_name || user?.last_name) ? `${user.first_name} ${user.last_name}`.trim() : user?.username;
      setCurrentDoc(prev => ({
        ...prev,
        ...(updatedDoc || {}),
        status: 'approved',
        approved_at: updatedDoc?.approved_at || new Date().toISOString(),
        approved_by_name: prev.approved_by_name || userDisplayName
      }));
      setActionSuccessMsg('Document approved and active master!');
      if (onUpdate) onUpdate();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to approve document.');
    } finally {
      setActionLoading(false);
    }
  };

  const handleRejectSubmit = async () => {
    if (!rejectComment.trim()) {
      setRejectError('Please enter a rejection reason.');
      return;
    }
    setActionLoading(true);
    setRejectError('');
    try {
      await rejectDocument(currentDoc.id, rejectComment);
      setCurrentDoc(prev => ({ ...prev, status: 'rejected' }));
      setShowRejectModal(false);
      setRejectComment('');
      setActionSuccessMsg('Document has been rejected.');
      if (onUpdate) onUpdate();
    } catch (err) {
      setRejectError(err.response?.data?.error || 'Failed to reject document.');
    } finally {
      setActionLoading(false);
    }
  };

  return (
    <div style={{
      position: 'fixed',
      inset: 0,
      backgroundColor: 'rgba(15, 23, 42, 0.75)',
      backdropFilter: 'blur(4px)',
      zIndex: 1200,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: isFullscreen ? '0' : '20px',
      transition: 'all 0.2s ease',
    }}>
      {!canPrintDoc && (
        <style>{`
          @media print {
            body * { visibility: hidden !important; }
            body::after {
              content: "Printing is restricted for this document by Document Control Policy.";
              visibility: visible !important;
              display: block !important;
              position: fixed !important;
              top: 40% !important;
              left: 10% !important;
              right: 10% !important;
              text-align: center !important;
              font-size: 20px !important;
              font-weight: bold !important;
              color: #dc2626 !important;
            }
          }
        `}</style>
      )}
      <div style={{
        backgroundColor: '#ffffff',
        borderRadius: isFullscreen ? '0' : '16px',
        width: isFullscreen ? '100vw' : '94vw',
        height: isFullscreen ? '100vh' : '92vh',
        maxWidth: isFullscreen ? 'none' : '1500px',
        display: 'flex',
        flexDirection: 'column',
        boxShadow: '0 25px 60px rgba(0,0,0,0.25)',
        overflow: 'hidden',
      }}>
        {/* Header Bar */}
        <div style={{
          padding: '14px 22px',
          borderBottom: '1px solid #e2e8f0',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          backgroundColor: '#f8fafc',
          flexShrink: 0,
          gap: '12px',
          flexWrap: 'wrap'
        }}>
          {/* Left: Document Info */}
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <div style={{
              width: '40px',
              height: '40px',
              borderRadius: '10px',
              backgroundColor: '#e0e7ff',
              color: '#4f46e5',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontWeight: '700',
              fontSize: '18px',
              flexShrink: 0,
            }}>
              {isPdf ? '📕' : isOfficeDoc ? '📊' : isImage ? '🖼️' : '📄'}
            </div>
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
                <span style={{ fontSize: '15px', fontWeight: '700', color: '#0f172a' }}>
                  {currentDoc.title}
                </span>
                <span style={{
                  fontSize: '11px',
                  fontWeight: '700',
                  padding: '2px 8px',
                  borderRadius: '12px',
                  backgroundColor: levelInfo.bg,
                  color: levelInfo.color,
                  border: `1px solid ${levelInfo.border}`,
                }}>
                  {currentDoc.doc_level || 'L2'}
                </span>
                <span style={{
                  fontSize: '11px',
                  fontWeight: '700',
                  padding: '2px 8px',
                  borderRadius: '12px',
                  backgroundColor: '#e2e8f0',
                  color: '#334155',
                }}>
                  Rev {currentDoc.revision ?? '0'}
                </span>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginTop: '3px', fontSize: '12px', color: '#64748b', flexWrap: 'wrap' }}>
                <span><strong>Doc No:</strong> {currentDoc.document_number}</span>
                {currentDoc.file_name && (
                  <>
                    <span>•</span>
                    <span style={{ maxWidth: '240px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {currentDoc.file_name}
                    </span>
                  </>
                )}
                {currentDoc.file_size_display && (
                  <>
                    <span>•</span>
                    <span>{currentDoc.file_size_display}</span>
                  </>
                )}
              </div>
            </div>
          </div>

          {/* Right: Actions */}
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
            {/* Workflow Action: Review & Recommend */}
            {canReview && (
              <button
                type="button"
                disabled={actionLoading}
                onClick={handleReview}
                style={{
                  padding: '7px 12px',
                  borderRadius: '8px',
                  border: 'none',
                  backgroundColor: '#2563eb',
                  color: '#ffffff',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '5px',
                  cursor: actionLoading ? 'not-allowed' : 'pointer',
                  boxShadow: '0 2px 6px rgba(37, 99, 235, 0.25)',
                }}
              >
                <CheckCircle size={14} /> Review & Recommend
              </button>
            )}

            {/* Workflow Action: Approve Document */}
            {canApprove && (
              <button
                type="button"
                disabled={actionLoading}
                onClick={handleApprove}
                style={{
                  padding: '7px 12px',
                  borderRadius: '8px',
                  border: 'none',
                  backgroundColor: '#059669',
                  color: '#ffffff',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '5px',
                  cursor: actionLoading ? 'not-allowed' : 'pointer',
                  boxShadow: '0 2px 6px rgba(5, 150, 105, 0.25)',
                }}
              >
                <CheckCircle size={14} /> Approve Document
              </button>
            )}

            {/* Workflow Action: Reject */}
            {canReject && (
              <button
                type="button"
                disabled={actionLoading}
                onClick={() => setShowRejectModal(true)}
                style={{
                  padding: '7px 12px',
                  borderRadius: '8px',
                  border: '1px solid #fca5a5',
                  backgroundColor: '#fef2f2',
                  color: '#dc2626',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '5px',
                  cursor: actionLoading ? 'not-allowed' : 'pointer',
                }}
              >
                <X size={14} /> Reject
              </button>
            )}

            {canRequestDCR && (
              <button
                onClick={() => {
                  onClose();
                  onRequestDCR(currentDoc);
                }}
                style={{
                  padding: '7px 12px',
                  borderRadius: '8px',
                  border: 'none',
                  backgroundColor: '#4f46e5',
                  color: '#ffffff',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '6px',
                  cursor: 'pointer',
                  boxShadow: '0 2px 6px rgba(79, 70, 229, 0.25)',
                }}
              >
                <Edit3 size={14} /> Request DCR
              </button>
            )}

            {canPrintDoc && (
              <button
                type="button"
                onClick={() => {
                  if (isPdf && documentUrl) {
                    const printWin = window.open(documentUrl, '_blank');
                    if (printWin) {
                      printWin.onload = () => {
                        printWin.focus();
                        printWin.print();
                      };
                    } else {
                      window.print();
                    }
                  } else {
                    window.print();
                  }
                }}
                title="Print Document"
                style={{
                  padding: '7px 11px',
                  borderRadius: '8px',
                  border: '1px solid #cbd5e1',
                  backgroundColor: '#ffffff',
                  color: '#334155',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '5px',
                  cursor: 'pointer',
                }}
              >
                <Printer size={14} /> Print
              </button>
            )}

            {canDownloadDoc && (
              <a
                href={getDownloadUrl(currentDoc.id)}
                onClick={(event) => { event.preventDefault(); downloadDocument(currentDoc.id, currentDoc.file_name); }}
                target="_blank"
                rel="noreferrer"
                title="Download original document file"
                style={{
                  padding: '7px 11px',
                  borderRadius: '8px',
                  border: '1px solid #cbd5e1',
                  backgroundColor: '#ffffff',
                  color: '#334155',
                  fontSize: '12px',
                  fontWeight: '600',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '5px',
                  textDecoration: 'none',
                }}
              >
                <Download size={14} /> Download
              </a>
            )}

            <button
              onClick={() => setIsFullscreen(!isFullscreen)}
              title={isFullscreen ? "Exit fullscreen" : "Fullscreen"}
              style={{
                background: 'none',
                border: '1px solid #cbd5e1',
                borderRadius: '8px',
                padding: '7px',
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                color: '#64748b',
              }}
            >
              {isFullscreen ? <Minimize2 size={16} /> : <Maximize2 size={16} />}
            </button>

            <button
              onClick={onClose}
              title="Close viewer"
              style={{
                background: '#fee2e2',
                border: 'none',
                borderRadius: '8px',
                padding: '7px',
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                color: '#dc2626',
              }}
            >
              <X size={17} />
            </button>
          </div>
        </div>

        {/* Sign-off & Audit Strip */}
        <div style={{
          padding: '8px 22px',
          background: '#ffffff',
          borderBottom: '1px solid #e2e8f0',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          fontSize: '12px',
          color: '#475569',
          flexWrap: 'wrap',
          gap: '12px'
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '14px', flexWrap: 'wrap' }}>
            <span>
              <strong style={{ color: '#0f172a' }}>Prepared by:</strong> {currentDoc.uploaded_by_name || 'Admin'}
            </span>
            <span style={{ color: '#cbd5e1' }}>•</span>
            <span>
              <strong style={{ color: '#0f172a' }}>Reviewed by:</strong> {currentDoc.reviewed_by_name || 'Not assigned'}
              {(currentDoc.reviewed_at || currentDoc.status === 'awaiting_approval' || currentDoc.status === 'approved') && (
                <span style={{ color: '#059669', fontWeight: '700', marginLeft: '5px' }}>
                  ✓ Reviewed
                </span>
              )}
            </span>
            <span style={{ color: '#cbd5e1' }}>•</span>
            <span>
              <strong style={{ color: '#0f172a' }}>Approved by:</strong> {currentDoc.approved_by_name || 'Not assigned'}
              {(currentDoc.approved_at || currentDoc.status === 'approved') && (
                <span style={{ color: '#059669', fontWeight: '700', marginLeft: '5px' }}>
                  ✓ Approved
                </span>
              )}
            </span>
            {currentDoc.revision_date && (
              <>
                <span style={{ color: '#cbd5e1' }}>•</span>
                <span>
                  <strong style={{ color: '#0f172a' }}>Rev Date:</strong> {currentDoc.revision_date}
                </span>
              </>
            )}
            {currentDoc.effective_date && (
              <>
                <span style={{ color: '#cbd5e1' }}>•</span>
                <span>
                  <strong style={{ color: '#0f172a' }}>Effective:</strong> {currentDoc.effective_date}
                </span>
              </>
            )}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            {actionSuccessMsg && (
              <span style={{
                backgroundColor: '#dcfce7',
                border: '1px solid #86efac',
                color: '#15803d',
                padding: '3px 10px',
                borderRadius: '8px',
                fontWeight: '700',
                fontSize: '12px',
                display: 'inline-flex',
                alignItems: 'center',
                gap: '5px'
              }}>
                <CheckCircle size={13} /> {actionSuccessMsg}
              </span>
            )}
            <span style={{
              fontSize: '11px',
              fontWeight: '700',
              padding: '3px 9px',
              borderRadius: '12px',
              backgroundColor:
                currentDoc.status === 'approved' ? '#ecfdf5' :
                currentDoc.status === 'awaiting_approval' ? '#eff6ff' :
                currentDoc.status === 'under_review' ? '#fef3c7' :
                currentDoc.status === 'rejected' ? '#fef2f2' : '#f8fafc',
              color:
                currentDoc.status === 'approved' ? '#059669' :
                currentDoc.status === 'awaiting_approval' ? '#1d4ed8' :
                currentDoc.status === 'under_review' ? '#d97706' :
                currentDoc.status === 'rejected' ? '#dc2626' : '#64748b',
              border: `1px solid ${
                currentDoc.status === 'approved' ? '#a7f3d0' :
                currentDoc.status === 'awaiting_approval' ? '#bfdbfe' :
                currentDoc.status === 'under_review' ? '#fde68a' :
                currentDoc.status === 'rejected' ? '#fca5a5' : '#e2e8f0'
              }`,
              textTransform: 'uppercase',
              letterSpacing: '0.4px'
            }}>
              {currentDoc.status === 'awaiting_approval' ? 'Awaiting Approval' : currentDoc.status?.replace('_', ' ')}
            </span>
          </div>
        </div>

        {/* Content Viewer Body */}
        <div style={{
          flex: 1,
          backgroundColor: '#0f172a',
          position: 'relative',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          overflow: 'hidden',
        }}>
          {!canPreviewDoc ? (
            <div style={{
              textAlign: 'center',
              backgroundColor: '#ffffff',
              padding: '40px',
              borderRadius: '16px',
              maxWidth: '440px',
              boxShadow: '0 10px 25px rgba(0,0,0,0.2)',
              margin: '20px'
            }}>
              <Shield size={48} color="#ef4444" style={{ marginBottom: '16px' }} />
              <h3 style={{ margin: '0 0 8px 0', fontSize: '18px', color: '#0f172a' }}>
                Preview Access Restricted
              </h3>
              <p style={{ margin: '0 0 16px 0', fontSize: '13px', color: '#64748b' }}>
                You do not have permission to preview the contents of this document.
              </p>
              {canDownloadDoc && (
                <a
                  href={getDownloadUrl(currentDoc.id)}
                  onClick={(event) => { event.preventDefault(); downloadDocument(currentDoc.id, currentDoc.file_name); }}
                  target="_blank"
                  rel="noreferrer"
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '8px',
                    backgroundColor: '#059669',
                    color: '#ffffff',
                    padding: '9px 18px',
                    borderRadius: '8px',
                    textDecoration: 'none',
                    fontWeight: '600',
                    fontSize: '13px',
                  }}
                >
                  <Download size={15} /> Download Document
                </a>
              )}
            </div>
          ) : documentUrl ? (
            isImage ? (
              <div style={{
                width: '100%',
                height: '100%',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                padding: '20px',
                boxSizing: 'border-box',
                overflow: 'auto',
              }}>
                <img
                  src={documentUrl}
                  alt={currentDoc.title}
                  style={{
                    maxWidth: '100%',
                    maxHeight: '100%',
                    objectFit: 'contain',
                    borderRadius: '8px',
                    boxShadow: '0 8px 30px rgba(0,0,0,0.5)',
                  }}
                />
              </div>
            ) : embedUrl ? (
              <div style={{ width: '100%', height: '100%', position: 'relative' }}>
                {iframeLoading && (
                  <div style={{
                    position: 'absolute',
                    inset: 0,
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'center',
                    justifyContent: 'center',
                    backgroundColor: '#1e293b',
                    color: '#94a3b8',
                    zIndex: 2,
                  }}>
                    <RefreshCw size={26} style={{ animation: 'spin 1s linear infinite', marginBottom: '12px', color: '#6366f1' }} />
                    <span style={{ fontSize: '13px', fontWeight: '500' }}>Opening document in viewer...</span>
                  </div>
                )}
                <iframe
                  key={embedUrl}
                  src={embedUrl}
                  title={currentDoc.title}
                  onLoad={() => setIframeLoading(false)}
                  allowFullScreen
                  style={{
                    width: '100%',
                    height: '100%',
                    border: 'none',
                    backgroundColor: isPdf ? '#334155' : '#ffffff',
                  }}
                />
              </div>
            ) : (
              <div style={{
                textAlign: 'center',
                backgroundColor: '#ffffff',
                padding: '40px',
                borderRadius: '16px',
                maxWidth: '480px',
                boxShadow: '0 10px 25px rgba(0,0,0,0.2)',
              }}>
                <FileText size={48} color="#4f46e5" style={{ marginBottom: '16px' }} />
                <h3 style={{ margin: '0 0 8px 0', fontSize: '18px', color: '#0f172a' }}>{currentDoc.file_name}</h3>
                <p style={{ margin: '0 0 20px 0', fontSize: '13px', color: '#64748b' }}>
                  Click below to open or download the original file.
                </p>
                <a
                  href={canDownloadDoc ? getDownloadUrl(currentDoc.id) : documentUrl}
                  onClick={canDownloadDoc ? (event) => { event.preventDefault(); downloadDocument(currentDoc.id, currentDoc.file_name); } : undefined}
                  target="_blank"
                  rel="noreferrer"
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '8px',
                    backgroundColor: '#4f46e5',
                    color: '#ffffff',
                    padding: '10px 20px',
                    borderRadius: '8px',
                    textDecoration: 'none',
                    fontWeight: '600',
                    fontSize: '14px',
                  }}
                >
                  <ExternalLink size={16} /> Open Document
                </a>
              </div>
            )
          ) : (
            <div style={{ textAlign: 'center', color: '#94a3b8' }}>
              <AlertCircle size={40} style={{ marginBottom: '12px' }} />
              <p style={{ margin: 0, fontSize: '15px' }}>No file attached to this document record.</p>
            </div>
          )}
        </div>
      </div>

      {/* Reject Modal */}
      {showRejectModal && (
        <div style={{
          position: 'fixed',
          inset: 0,
          background: 'rgba(15,23,42,0.65)',
          zIndex: 1300,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '20px'
        }}>
          <div style={{
            background: '#ffffff',
            borderRadius: '16px',
            width: '100%',
            maxWidth: '460px',
            boxShadow: '0 25px 60px rgba(0,0,0,0.25)',
            overflow: 'hidden'
          }}>
            <div style={{
              padding: '18px 24px',
              borderBottom: '1px solid #f1f5f9',
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center'
            }}>
              <div>
                <h3 style={{ margin: 0, fontSize: '16px', fontWeight: '700', color: '#0f172a' }}>
                  Reject Controlled Document
                </h3>
                <p style={{ margin: '3px 0 0', fontSize: '12px', color: '#64748b' }}>
                  {currentDoc.document_number} : {currentDoc.title}
                </p>
              </div>
              <button
                type="button"
                onClick={() => { setShowRejectModal(false); setRejectError(''); }}
                style={{ background: 'none', border: 'none', cursor: 'pointer', padding: '4px' }}
              >
                <X size={18} color="#94a3b8" />
              </button>
            </div>

            <div style={{ padding: '20px 24px' }}>
              <label style={{ display: 'block', fontSize: '12px', fontWeight: '700', color: '#374151', marginBottom: '6px' }}>
                Rejection Reason *
              </label>
              <textarea
                rows={4}
                value={rejectComment}
                onChange={(e) => setRejectComment(e.target.value)}
                placeholder="Explain the issues found or corrections required before resubmission..."
                style={{
                  width: '100%',
                  padding: '10px 12px',
                  borderRadius: '8px',
                  border: '1px solid #e2e8f0',
                  fontSize: '13px',
                  outline: 'none',
                  boxSizing: 'border-box',
                  fontFamily: 'inherit'
                }}
              />

              {rejectError && (
                <div style={{
                  background: '#fee2e2',
                  color: '#dc2626',
                  padding: '8px 12px',
                  borderRadius: '8px',
                  fontSize: '12px',
                  marginTop: '10px',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '6px'
                }}>
                  <AlertTriangle size={14} /> {rejectError}
                </div>
              )}

              <div style={{ display: 'flex', gap: '10px', justifyContent: 'flex-end', marginTop: '16px' }}>
                <button
                  type="button"
                  onClick={() => { setShowRejectModal(false); setRejectError(''); }}
                  style={{
                    padding: '8px 16px',
                    borderRadius: '8px',
                    border: '1px solid #e2e8f0',
                    background: '#ffffff',
                    fontSize: '13px',
                    fontWeight: '600',
                    color: '#64748b',
                    cursor: 'pointer'
                  }}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={actionLoading}
                  onClick={handleRejectSubmit}
                  style={{
                    padding: '8px 18px',
                    borderRadius: '8px',
                    border: 'none',
                    background: '#dc2626',
                    color: '#ffffff',
                    fontSize: '13px',
                    fontWeight: '700',
                    cursor: actionLoading ? 'not-allowed' : 'pointer'
                  }}
                >
                  {actionLoading ? 'Rejecting...' : 'Reject Document'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
