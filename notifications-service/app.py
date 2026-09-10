import os
import smtplib
import logging
import traceback
from email.message import EmailMessage
from flask import Flask, request, jsonify

# --- Config from environment ---
PORT = int(os.environ.get('PORT', 3002))
HOST = os.environ.get('HOST', '0.0.0.0')
SMTP_HOST = os.environ.get('SMTP_HOST', 'smtp.gmail.com')  # 🐛 FIXED: was 'HOST'
SMTP_PORT = int(os.environ.get('SMTP_PORT', 587))
SMTP_USER = os.environ.get('SMTP_USER')
SMTP_PASSWORD = os.environ.get('SMTP_PASSWORD')
SMTP_FROM = os.environ.get('SMTP_FROM', SMTP_USER)
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO').upper()

# Validate required secrets at startup
if not SMTP_USER or not SMTP_PASSWORD:
    raise SystemExit('❌ SMTP_USER and SMTP_PASSWORD env vars are required')

# --- Logging setup ---
logging.basicConfig(
    level=LOG_LEVEL,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
log = logging.getLogger(__name__)

app = Flask(__name__)

# --- Request/response logging middleware ---
@app.before_request
def log_request():
    log.info(f'→ {request.method} {request.path} from {request.remote_addr}')

@app.after_request
def log_response(response):
    log.info(f'← {request.method} {request.path} returned {response.status_code}')
    return response


def send_email(to, subject, message):
    """Send an email via SMTP — with detailed step-by-step logging."""
    log.info(f'Building email: to={to}, subject="{subject}", body_len={len(message)}')
    msg = EmailMessage()
    msg['From'] = SMTP_FROM
    msg['To'] = to
    msg['Subject'] = subject
    msg.set_content(message)

    log.info(f'Connecting to SMTP {SMTP_HOST}:{SMTP_PORT}...')
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
            log.info('✓ TCP connected to SMTP server')

            log.info('Starting TLS handshake...')
            server.starttls()
            log.info('✓ TLS negotiated')

            log.info(f'Authenticating as {SMTP_USER}...')
            server.login(SMTP_USER, SMTP_PASSWORD)
            log.info('✓ SMTP authentication successful')

            log.info('Sending message...')
            server.send_message(msg)
            log.info(f'📧 Email sent → {to}: "{subject}"')

    except smtplib.SMTPAuthenticationError as err:
        log.error(f'🔐 SMTP authentication failed — wrong username or password')
        log.error(f'  Details: {err}')
        log.error(f'  Hint: For Gmail, you need an App Password (16 chars), not your regular password')
        log.error(f'  Generate one at: https://myaccount.google.com/apppasswords')
        raise

    except smtplib.SMTPConnectError as err:
        log.error(f'🔌 Could not connect to SMTP server {SMTP_HOST}:{SMTP_PORT}')
        log.error(f'  Details: {err}')
        log.error(f'  Hint: Check SMTP_HOST and SMTP_PORT are correct')
        raise

    except smtplib.SMTPServerDisconnected as err:
        log.error(f'📡 SMTP server disconnected ')
        log.error(f'  Details: {err}')
        raise

    except smtplib.SMTPException as err:
        log.error(f'✉️ Generic SMTP error: {type(err).__name__}')
        log.error(f'  Details: {err}')
        raise

    except (TimeoutError, ConnectionRefusedError) as err:
        log.error(f'⏱️ Network error reaching {SMTP_HOST}:{SMTP_PORT}')
        log.error(f'  Error type: {type(err).__name__}')
        log.error(f'  Details: {err}')
        raise

    except Exception as err:
        log.error(f'💥 Unexpected error: {type(err).__name__}')
        log.error(f'  Details: {err}')
        log.error(f'  Stack trace:\n{traceback.format_exc()}')
        raise


@app.route('/notify', methods=['POST'])
def notify():
    log.info('Processing /notify request...')

    data = request.get_json() or {}
    to = data.get('to')
    subject = data.get('subject', 'Notification')
    message = data.get('message', '')

    log.info(f'Request body: to={to}, subject="{subject}", body_len={len(message)}')

    if not to:
        log.warning('⚠️ Request rejected: missing "to" field')
        return jsonify({'sent': False, 'error': '"to" field required'}), 400

    try:
        send_email(to, subject, message)
        log.info('✅ /notify completed successfully')
        return jsonify({'sent': True})

    except Exception as err:
        error_type = type(err).__name__
        error_msg = str(err)
        log.error(f'❌ /notify failed: [{error_type}] {error_msg}')
        return jsonify({
            'sent': False,
            'error': error_msg,
            'error_type': error_type
        }), 500


@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'ok',
        'service': 'notification',
        'runtime': 'python',
        'smtp_host': SMTP_HOST,
        'smtp_port': SMTP_PORT,
        'smtp_user_configured': bool(SMTP_USER)
    })


if __name__ == '__main__':
    log.info('=' * 60)
    log.info(f'🐍 Notification service (Flask) starting...')
    log.info(f'📮 SMTP config: {SMTP_HOST}:{SMTP_PORT} as {SMTP_USER}')
    log.info(f'🌐 Listening on http://{HOST}:{PORT}')
    log.info(f'📊 Log level: {LOG_LEVEL}')
    log.info('=' * 60)
    app.run(host=HOST, port=PORT)
    log.info(f'trigger first commit')