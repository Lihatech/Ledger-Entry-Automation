import { useState, useRef, useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMessaging } from '../context/MessagingContext';
import ConversationList from '../components/messaging/ConversationList';
import ChatWindow from '../components/messaging/ChatWindow';
import UserSearch from '../components/messaging/UserSearch';
import GroupCreation from '../components/messaging/GroupCreation';
import CreateMeet from '../components/messaging/CreateMeet';
import { Plus, MessageCircle, Users, ChevronDown, Video } from 'lucide-react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { useMessageNotifications } from '../context/MessageNotificationContext';
import './MessagesPage.css';

export default function MessagesPage() {
  const [showUserSearch, setShowUserSearch] = useState(false);
  const [showGroupCreation, setShowGroupCreation] = useState(false);
  const [showMeetCreation, setShowMeetCreation] = useState(false);
  const [showDropdown, setShowDropdown] = useState(false);
  const dropdownRef = useRef(null);
  const [searchParams] = useSearchParams();
  const { markAllMessageNotificationsRead } = useMessageNotifications();

  const initialConversationId = searchParams.get('conversation')
    ? parseInt(searchParams.get('conversation'), 10)
    : null;

  const { setPendingConversationId } = useMessaging();

  useEffect(() => {
    if (initialConversationId) {
      setPendingConversationId(initialConversationId);
    }
  }, [initialConversationId, setPendingConversationId]);

  // Mark all message notifications read when user opens the messages page
  useEffect(() => {
    markAllMessageNotificationsRead();
  }, [markAllMessageNotificationsRead]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setShowDropdown(false);
      }
    };

    if (showDropdown) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [showDropdown]);

  const handleNewChat = () => {
    setShowDropdown(false);
    setShowUserSearch(true);
  };

  const handleNewGroup = () => {
    setShowDropdown(false);
    setShowGroupCreation(true);
  };

  const handleNewMeet = () => {
    setShowDropdown(false);
    setShowMeetCreation(true);
  };

  return (
    <>
      <Header
        title="Messages"
        showLiveStatus={false}
      />
      <div className="messages-page" style={{ paddingTop: 'var(--header-height)', height: '100vh', boxSizing: 'border-box' }}>
        <div className="messages-layout">
          <div className="conversations-panel">
            <div style={{ padding: '12px 16px 4px' }}>
              <Breadcrumbs items={[{ label: 'Messages' }]} className="mb-0" />
            </div>
            <ConversationList />

            <div className="new-action-container" ref={dropdownRef}>
              <button
                className="new-chat-button"
                onClick={() => setShowDropdown(!showDropdown)}
              >
                <Plus size={20} />
                <span>New</span>
                <ChevronDown size={16} className={`dropdown-icon ${showDropdown ? 'open' : ''}`} />
              </button>

              {showDropdown && (
                <div className="new-action-dropdown">
                  <button className="dropdown-item" onClick={handleNewChat}>
                    <MessageCircle size={18} />
                    <span>New Chat</span>
                  </button>
                  <button className="dropdown-item" onClick={handleNewGroup}>
                    <Users size={18} />
                    <span>New Group</span>
                  </button>
                  <button className="dropdown-item" onClick={handleNewMeet}>
                    <Video size={18} />
                    <span>Create Meet</span>
                  </button>
                </div>
              )}
            </div>
          </div>

          <div className="chat-panel">
            <ChatWindow />
          </div>
        </div>

        {showUserSearch && (
          <UserSearch onClose={() => setShowUserSearch(false)} />
        )}

        {showGroupCreation && (
          <GroupCreation onClose={() => setShowGroupCreation(false)} />
        )}

        {showMeetCreation && (
          <CreateMeet onClose={() => setShowMeetCreation(false)} />
        )}
      </div>
    </>
  );
}
