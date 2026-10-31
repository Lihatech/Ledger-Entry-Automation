# WebSocket Authentication Security Documentation

## Current Implementation

The messaging module supports JWT authentication through either the legacy query
string protocol or a first-frame authentication message. New clients should use
the first-frame protocol; the query-string form remains available for existing
mobile and third-party clients during migration.

### Connection Format
```
ws://localhost:8000/ws/messaging/{conversation_id}/?token={jwt_token}
```

New clients should connect without a token in the URL and immediately send:

```json
{"action":"auth","token":"<jwt_token>"}
```

Connections without a valid URL token or first-frame authentication message are
closed after 10 seconds.

## Security Considerations

### ⚠️ Known Security Tradeoff

**Issue**: JWT tokens are passed in the WebSocket URL query string.

**Security Implications**:
1. **Server Logs**: Web servers (Daphne, Nginx, etc.) typically log full request URLs including query parameters
2. **Proxy Logs**: Reverse proxies and load balancers may log the connection URL
3. **Browser History**: In browser-based clients, WebSocket URLs may appear in developer tools
4. **Audit Trails**: Security monitoring systems often capture full URLs

**Impact**: An attacker with access to server logs, proxy logs, or monitoring systems could extract valid JWT tokens and potentially impersonate users.

---

## Risk Mitigation Strategies

### 1. **Token Rotation (Recommended)**
Implement aggressive token rotation to limit exposure window:

- **Short Token Lifetime**: Keep access tokens short-lived (5-15 minutes)
- **Refresh Token Pattern**: Use refresh tokens to obtain new access tokens
- **Rotate on WebSocket Reconnect**: Generate new token for each reconnection attempt

**Implementation**:
```python
# In settings.py
SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(minutes=15),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=7),
    'ROTATE_REFRESH_TOKENS': True,
    'BLACKLIST_AFTER_ROTATION': True,
}
```

### 2. **Log Sanitization**
Configure web servers to sanitize query parameters from logs:

**Nginx Configuration**:
```nginx
log_format sanitized '$remote_addr - $remote_user [$time_local] '
                     '"$request_method $uri $server_protocol" '
                     '$status $body_bytes_sent';
access_log /var/log/nginx/access.log sanitized;
```

### 3. **Monitor and Alert**
Implement monitoring for suspicious patterns:
- Multiple connections from different IPs with same token
- Tokens used after user logout
- Abnormal reconnection rates

---

## Recommendations

### Immediate Actions
1. ✅ Configure short token lifetime (15 minutes)
2. ✅ Implement log sanitization in production
3. ✅ Document token rotation policy

### Future Enhancements
1. Remove the legacy query-string protocol after all clients have migrated
2. Implement connection-specific tokens
3. Add token revocation monitoring

---

**Risk Level**: Medium  
**Acceptable For**: Internal applications with secured infrastructure  
**Last Updated**: 2026-09-09
