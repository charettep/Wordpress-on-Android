Install, self-host, deploy and expose safely a wordpress server on your Android phone
tested on a Pixel 6a Beta build BP41.250916.012
you will required a cloudflared account sign up for free here https://dash.cloudflare.com/sign-up or log in here https://dash.cloudflare.com/login

Requirements:
- Cloudflare Account
- Active Cloudflare domain
- Cloudflare API Token with these permissions -> <img width="913" height="610" alt="cloudflare_API_TOKEN" src="https://github.com/user-attachments/assets/b23feefe-7a7c-41b3-9d63-d1b5fd112e76" />
- Android Phone running Android 15 or latest

on android phone:
1. Go to Settings > About Phone > Build Number (tap 7 times real fast -> You are now a developer!)
2. Go to Settings > System > Developer options > Linux development environment > (toggle ON)
3. Pull your apps drawer and search for "Terminal" > launch "Terminal" app > Allow app to send notifications > Tap "Install" (bottom right button)
4. Wait a couple seconds until the terminal fully initializes > You should see text in a green font like "droid@debian:~$"
5. Type or copy/paste the following commands and press enter:
     ```bash
     sudo apt update;sudo apt upgrade -y;sudo apt install -y curl;curl -fsSL https://raw.githubusercontent.com/charettep/lde-scripts/main/wp+cf.sh -o /tmp/wp+cf.sh;chmod +x /tmp/wp+cf.sh;sudo /tmp/wp+cf.sh
     ```
6. The script will launch and prompt you to enter your Cloudflare API Token (with permissions as show here). Paste your token and press Enter
7. The script will prompt you to enter the hostname where you wish your Wordpress website to be publicly accessible. Enter full hostname, including subdomain (must be on a base domain active in your CF account), example: blog.charettep.com where charettep.com is my domain active in my cloudflare account. Then press Enter, and watch the magic happen :)
8. Stay alert and pay attention to your screen, as the script will need to open ports for docker, mariadb and cloudflared. As soon as you see the prompts, tap "Allow" or the script may break if you dont allow port access in time
9. Once the script is done, you can go to your chosen hostname from any browser on any device with internet access to complete the 5seconds wordpress initial setup.
10. The whole stack is install as systemd service, so all you have to do to bring your website up or down, is open/close your "Terminal" app.
