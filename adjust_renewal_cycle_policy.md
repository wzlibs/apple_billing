NGHIỆP VỤ: TRACKING ADJUST CHO SUBSCRIPTION RENEWAL
=====================================================

1. MỤC TIÊU
-----------
Khi user mua subscription, app phải báo cáo doanh thu lên Adjust để
hệ thống có dữ liệu chính xác phục vụ tối ưu chiến dịch quảng cáo.

Dữ liệu phải phản ánh đúng thời điểm thực tế phát sinh doanh thu,
không được dồn nhiều chu kỳ vào cùng một ngày.


2. VẤN ĐỀ PHÁT SINH
--------------------
User không nhất thiết mở app mỗi chu kỳ gia hạn. Khi user quay lại
sau nhiều chu kỳ vắng mặt, app sẽ phát hiện nhiều chu kỳ chưa được log.

Ví dụ — subscription gia hạn hàng tháng:

  Chu kỳ 1 | 01/01 | User mua lần đầu, mở app  → ĐÃ LOG
  Chu kỳ 2 | 01/02 | User không mở app          → CHƯA LOG
  Chu kỳ 3 | 01/03 | User không mở app          → CHƯA LOG
  Chu kỳ 4 | 01/04 | User mở app                → ?

Nếu log cả chu kỳ 2, 3, 4 vào ngày 01/04 → Adjust ghi nhận 3 sự kiện
doanh thu dồn vào cùng một ngày → dữ liệu bị méo → hệ thống quảng cáo
đưa ra quyết định ngân sách sai lệch.


3. QUY TẮC XỬ LÝ
-----------------
Khi user mở app và app phát hiện nhiều chu kỳ chưa được log:

  a. Duyệt toàn bộ các chu kỳ từ lần mua đầu tiên đến hiện tại.

  b. Với mỗi chu kỳ chưa được log → đánh dấu là ĐÃ XỬ LÝ (mark vào
     SharedPreferences/UserDefaults) nhưng KHÔNG gửi lên Adjust.

  c. Chỉ gửi lên Adjust duy nhất chu kỳ MỚI NHẤT (chu kỳ hiện tại).

Kết quả với ví dụ trên:

  Chu kỳ 1 | 01/01 | Đã log từ trước            → BỎ QUA
  Chu kỳ 2 | 01/02 | Chưa log → mark đã xử lý   → KHÔNG GỬI ADJUST
  Chu kỳ 3 | 01/03 | Chưa log → mark đã xử lý   → KHÔNG GỬI ADJUST
  Chu kỳ 4 | 01/04 | Chưa log → mark đã xử lý   → GỬI ADJUST ✓


4. LÝ DO THIẾT KẾ NHƯ VẬY
--------------------------
- Doanh thu thực tế của chu kỳ 2 và 3 đã phát sinh đúng ngày của chúng
  (Apple đã trừ tiền user), nhưng vì app không có mặt để ghi nhận,
  việc báo cáo muộn sẽ làm lệch phân phối dữ liệu theo thời gian.

- Chấp nhận bỏ qua chu kỳ 2, 3 để đổi lấy dữ liệu phân phối đều,
  phản ánh đúng hành vi thực tế của user đang active.

- Adjust dùng dữ liệu này để tính ROAS và tối ưu targeting. Dữ liệu
  dồn cục sẽ khiến hệ thống hiểu sai về ngày nào user có giá trị cao,
  dẫn đến phân bổ ngân sách không hiệu quả.


5. CÁC TRƯỜNG HỢP ĐẶC BIỆT
----------------------------
- Chu kỳ đầu tiên (lần mua ban đầu): luôn log, xử lý riêng bởi
  hàm trackPurchase(), không đi qua luồng renewal.

- Nếu intro offer (free trial / giảm giá): chu kỳ đầu có thể có giá 0,
  trường hợp này bỏ qua không gửi Adjust.

- Nếu subscription bị revoke (refund / chargeback): không log, bỏ qua
  toàn bộ chu kỳ liên quan.

- Deduplication: mỗi chu kỳ có một key duy nhất dạng
  "cycle_{purchaseToken}_{chargeTimeMs}" lưu vào UserDefaults để đảm
  bảo không bao giờ log trùng dù app bị kill hay restart giữa chừng.


=====================================================