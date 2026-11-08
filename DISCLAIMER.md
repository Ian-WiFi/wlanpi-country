# Disclaimer

Last updated: 2026-11-07

Please read this before using the scripts, tools or data in this repository ("the Project").

## 1. What this is

The Project is a research and lab tool, shared for information and education. It is not a commercial product and it is not supported.

## 2. No warranty

The Project is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, accuracy and non-infringement. See also the [LICENSE](LICENSE).

## 3. Use at your own risk

The scripts do real things to the machine they run on. By running them you accept the risks, which include:

- **They run as root.** They load and unload kernel modules (`iwlwifi`, `iwlmvm`, `iwlmld`), bring network interfaces up and down, start and stop `hostapd`, stop `hostapd` processes they started earlier, and may re-enumerate network devices.
- **Wi-Fi connectivity on the card under test is lost** on every country. Do not run them over a Wi-Fi SSH session or on a machine whose Wi-Fi you depend on. Use a wired connection.
- **The system or the Wi-Fi card can hang or crash.** During development a system hang occurred during a driver reload and the card did not come back until after a power cycle. Abrupt power-off can cause data loss or file system damage. Repeated reloads and scans stress the hardware and generate heat.
- **They write a lot of files** (tens of megabytes per card) to the working folder.
- Possible damage to hardware, data or software, or loss of network access.

Run the Project only on a dedicated test device that you can afford to lose access to, and never on production or safety-critical systems.

## 4. Radio-frequency and regulatory responsibility

The Project makes a Wi-Fi radio **transmit**, announcing different countries' regulatory settings in turn. While a country is being tested, the access-point radio operates under that country's rules, which may differ from, and may not be permitted by, the rules where you are located.

You are solely responsible for complying with all radio-frequency, spectrum, safety and other laws and regulations that apply where you use it. In particular:

- use it only in an isolated or shielded setup (for example a shielded enclosure, a conducted connection or attenuators) and keep transmit power as low as practical,
- do not run it where it could interfere with networks or devices you do not own or operate,
- do not run it where transmitting is prohibited.

## 5. The results are not regulatory advice

Captures and analysis from the Project are observations of particular hardware, firmware, driver and kernel versions under particular conditions. They may be incomplete, wrong, or different on other firmware, drivers, hardware or conditions. They are **not** an authoritative statement of any country's regulations or of what a product is allowed to do, and must not be used to decide legal compliance, certification or product behaviour. Consult the relevant regulator or a qualified professional.

## 6. Third-party software, trademarks and affiliation

The Project depends on third-party software (for example the Linux kernel, `iw`, `hostapd` and Python), which is under its own licenses and is not covered by this Project's license. Intel, WLAN Pi, MediaTek and other names and marks are the property of their owners and are used only to identify the hardware and software the Project was tested with. The Project is independent and is not affiliated with, endorsed by or sponsored by Intel Corporation or the WLAN Pi project.

## 7. Limitation of liability

To the maximum extent permitted by law, the author(s) and contributors are not liable for any claim, damages, loss or other liability, whether in contract, tort or otherwise, arising from or in connection with the Project or its use, including damage to hardware, loss of data, loss of network access, regulatory violations, or any decisions made based on its results.

## 8. Changes

This document may change over time. The version in the repository's default branch applies.
