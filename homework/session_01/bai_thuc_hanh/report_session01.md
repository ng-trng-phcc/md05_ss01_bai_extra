# BÁO CÁO THỰC HÀNH SESSION 01 — QUICKBITE

## 1. Mục tiêu

Thiết lập tài khoản hệ thống riêng cho QuickBite User Service và thư mục
Development có quyền truy cập giới hạn. Tách quyền chạy ứng dụng khỏi tài khoản
`root`, ngăn đăng nhập trực tiếp và bảo vệ các tệp triển khai khỏi người dùng khác.

## 2. Môi trường thực hành

- **Host:** NixOS, desktop Hyprland; quản lý vòng đời lab bằng Docker Compose.
- **Lab:** Ubuntu 24.04 trong container `quickbite-lab`, môi trường Development.
- **Ứng dụng:** `identityservice`, Java 21, Gradle Wrapper 9.7.1, cổng 8080.
- **Cách ly:** mọi thao tác tạo user/group và quản lý `/opt/quickbite` được thực
  hiện bên trong Ubuntu. Không thay đổi user/group, Java, `/opt` hoặc dịch vụ của
  NixOS; container không được cấp privileged, không gắn Docker socket, không có
  host bind mount và không publish cổng 8080 ra host.

## 3. Các lệnh Linux đã sử dụng

Các đoạn lệnh sau được trích từ `setup-dev.sh` đã thực thi trong Ubuntu bằng
quyền root. Script kiểm tra user/group trước khi tạo để có thể chạy lại an toàn.
Đây không phải các lệnh được thực thi trên host NixOS.

### 3.1. Tạo group và system user

```bash
getent group quickbite-apps >/dev/null || groupadd --system quickbite-apps
if ! getent passwd user-svc >/dev/null; then
  useradd --system --gid quickbite-apps --groups quickbite \
    --no-create-home --home-dir /nonexistent --shell /bin/false user-svc
fi
usermod --append --groups quickbite user-svc
```

- `--system`: tạo tài khoản hệ thống; UID thực tế là `994`, thuộc khoảng system
  UID `100–999` đã kiểm tra trong cấu hình Ubuntu của lab.
- `--gid quickbite-apps`: đặt group chính của service.
- `--no-create-home --home-dir /nonexistent`: không tự tạo thư mục home cá nhân.
- `--shell /bin/false`: vô hiệu hóa phiên shell đăng nhập trực tiếp.
- `--groups quickbite` và lệnh `usermod --append`: bổ sung group `quickbite`,
  giữ các group đang có. Nhờ đó service truy cập được thư mục cha
  `/opt/quickbite` vốn có quyền `750` và sở hữu `quickbite:quickbite`.

### 3.2. Tạo thư mục, đặt ownership và mode

```bash
for path in /opt/quickbite/dev /opt/quickbite/dev/user-service; do
  [[ ! -L $path ]] || die "Refusing symlink: $path"
  mkdir -p "$path"
  chown user-svc:quickbite-apps "$path"
  chmod 750 "$path"
done
```

Đây là vòng lặp thực tế của script; `die` là hàm báo lỗi và kết thúc nếu gặp
symlink. `mkdir -p` không lỗi khi thư mục đã tồn tại. Ownership và mode chỉ được
áp dụng cho hai thư mục Development nêu trên, không dùng `chmod -R` hoặc đổi
ownership đệ quy lên cây QuickBite hiện có. Thư mục cha `/opt/quickbite` vẫn giữ
`750 quickbite:quickbite` từ bài trước.

### 3.3. Kiểm tra user/group và quyền truy cập

```bash
id user-svc
getent passwd user-svc
getent group quickbite-apps
stat -c '%A %a %U %G %n' /opt/quickbite/dev/user-service
```

Script còn kiểm tra khả năng truy cập thực tế bằng tài khoản dịch vụ:

```bash
runuser -u user-svc -- test -x /opt/quickbite/dev/user-service
```

`runuser` thực thi lệnh dưới quyền `user-svc` mà không cần mở phiên đăng nhập
shell; phù hợp với tài khoản có shell `/bin/false`.

## 4. Giải thích quyền 750

**`750 = rwxr-x---`**

| Đối tượng | Giá trị | Quyền |
|---|---:|---|
| Owner (`user-svc`) | 7 | Đọc, ghi và thực thi (`rwx`) |
| Group (`quickbite-apps`) | 5 | Đọc và thực thi, không được ghi (`r-x`) |
| Others | 0 | Không có quyền (`---`) |

Đối với thư mục: `r` cho phép liệt kê tên mục; `w` cho phép thêm/xóa/đổi tên mục,
phụ thuộc quyền `x` và các quy tắc filesystem khác; `x` cho phép đi qua thư mục
và truy cập mục theo tên. Vì cần quyền `x` trên mọi thư mục cha, service được
thêm vào group `quickbite` thay vì nới lỏng quyền `/opt/quickbite` cho Others.

## 5. Kết quả kiểm chứng

Output read-only thực tế lấy từ container đang chạy ngày **04/11/2026**:

```text
$ id user-svc
uid=994(user-svc) gid=994(quickbite-apps) groups=994(quickbite-apps),995(quickbite)
$ getent passwd user-svc
user-svc:x:994:994::/nonexistent:/bin/false
$ getent group quickbite-apps
quickbite-apps:x:994:
$ stat -c '%A %a %U %G %n' /opt/quickbite/dev/user-service
drwxr-x--- 750 user-svc quickbite-apps /opt/quickbite/dev/user-service
```

Kết quả xác nhận group chính đúng, shell đúng `/bin/false`, không tạo home cá
nhân và thư mục có ownership/mode đúng yêu cầu. Thiết lập lặp lại đã thành công.
Việc service chạy bằng `user-svc` cũng kiểm chứng quyền đọc/traverse cần thiết.

### Ảnh bằng chứng đính kèm

| Ảnh | Nội dung |
|---|---|
| [img_01.png](img_01.png) | Kiểm tra tài khoản/thư mục, Gradle build và deploy thành công |
| [img_02.png](img_02.png) | Lỗi `bootJar` chủ đích; deploy dừng với exit code 1, PID/SHA-256 giữ nguyên |
| [img_03.png](img_03.png) | TCP 8080 ở trạng thái LISTEN; HTTP 403 tại `/` do cấu hình bảo mật hiện có |

Các ảnh là bằng chứng người thực hành cung cấp. Ảnh thứ hai có dữ liệu JPEG
dù tên gốc là `.png`; bản nộp đã được chuyển đổi thật sang PNG, không crop,
không resize và không thay đổi nội dung điểm ảnh đã giải mã. Hai ảnh PNG còn
lại được sao chép nguyên bản.

## 6. Kết luận

Đã thiết lập thành công system user `user-svc`, group chính `quickbite-apps`
và thư mục `/opt/quickbite/dev/user-service` với quyền `750`. Tài khoản không
được cấp shell đăng nhập hoặc tự tạo home, vẫn có đủ quyền traverse/read cho
ứng dụng. Toàn bộ thao tác quản trị được giới hạn trong Ubuntu Docker Lab,
giữ nguyên cấu hình và tài khoản của host NixOS.
