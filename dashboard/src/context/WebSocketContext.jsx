import { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react';
import { WS_BASE_URL } from '../api/axios';

const WebSocketContext = createContext(null);

export function WebSocketProvider({ children, plantId }) {
  const [connected, setConnected]   = useState(false);
  const [events, setEvents]         = useState([]);   // last N live events
  const wsRef = useRef(null);
  const reconnectTimer = useRef(null);
  const connectRef = useRef(null);

  const connect = useCallback(() => {
    if (!plantId) return;
    const url   = `${WS_BASE_URL}/ws/dashboard/${plantId}/`;

    const ws = new WebSocket(url);
    wsRef.current = ws;

    ws.onopen = () => {
      const token = localStorage.getItem('access_token');
      ws.send(JSON.stringify({ type: 'auth', token }));

      setConnected(true);
      // Clear any reconnect timer
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
    };

    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        if (data.type === 'connected') return; // skip ack
        setEvents((prev) => [
          { ...data, _receivedAt: new Date().toISOString() },
          ...prev.slice(0, 49), // keep last 50 events
        ]);
      } catch { /* ignore parse errors */ }
    };

    ws.onclose = () => {
      setConnected(false);
      // Auto-reconnect after 3 seconds
      reconnectTimer.current = setTimeout(() => connectRef.current?.(), 3000);
    };

    ws.onerror = () => ws.close();
  }, [plantId]);

  useEffect(() => {
    connectRef.current = connect;
    connect();
    return () => {
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      const ws = wsRef.current;
      if (!ws) return;
      if (ws.readyState === WebSocket.OPEN) {
        ws.close();
      } else if (ws.readyState === WebSocket.CONNECTING) {
        // StrictMode: socket not open yet — defer close to avoid browser warning
        ws.onopen = () => ws.close();
      }
    };
  }, [connect]);

  // Allow components to clear the event list
  const clearEvents = useCallback(() => setEvents([]), []);

  return (
    <WebSocketContext.Provider value={{ connected, events, clearEvents }}>
      {children}
    </WebSocketContext.Provider>
  );
}

export function useWebSocket() {
  return useContext(WebSocketContext);
}
