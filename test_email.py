import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.utils import formataddr

def send_email():
    # Email configuration
    smtp_server = 
    smtp_port = 465
    sender_email = 
    sender_name = 
    password = 
    recipient_email = 

    # Create message
    msg = MIMEMultipart()
    msg['From'] = formataddr((sender_name, sender_email))
    msg['To'] = recipient_email
    msg['Subject'] = "Python SMTP SSL Test"

    body = "This is a test email sent using Python with SSL/TLS settings"
    msg.attach(MIMEText(body, 'plain'))

    try:
        # Create SSL connection
        server = smtplib.SMTP_SSL(smtp_server, smtp_port)
        server.login(sender_email, password)
        
        # Send email
        text = msg.as_string()
        server.sendmail(sender_email, recipient_email, text)
        print("Email sent successfully!")
        
    except Exception as e:
        print(f"Error: {str(e)}")
        
    finally:
        server.quit()

if __name__ == "__main__":
    send_email()