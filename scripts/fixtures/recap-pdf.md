# "Clinic booking app review" — Meeting Recap

Source: recording "Clinic booking app review" (~25 min, Khmer with English terms). Transcript: `clinic.transcript.txt`. Names are not reliable, so attribution is by role.

A weekly review between the product owner and developers. Topics: booking, payments and launch.

## សង្ខេប

- អ្នកជំងឺអាចកក់ពេលដោយមិនចាំបាច់មានគណនី ប្រើតែលេខទូរស័ព្ទ និងលេខកូដ SMS ប៉ុណ្ណោះ។
- មានបញ្ហាកាត់ប្រាក់កក់ពីរដង ពេលអ៊ីនធឺណិតយឺត ដែលមិនទាន់ដោះស្រាយនៅឡើយ។

## 1. Booking flow

- **Decision:** No account is needed. Patients choose a doctor and a 15-minute slot.
- **Pending:** Telegram reminders are parked until after launch.

## 2. Payments

- **Deposit:** A 5 USD deposit is refunded when a patient cancels 24 hours ahead.
- **Payment bug:** Duplicate charges remain unresolved. Developers will add a lock and verify the callback.

## Next steps

- Developers: fix the duplicate charge and add the daily totals.
- Product owner: set the launch date once the fix is tested.

[topic times] 1=00:12, 2=09:40
