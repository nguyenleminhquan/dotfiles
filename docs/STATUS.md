# Status (tạm thời)

File ghi tình hình làm việc, sẽ xoá khi xong đợt này. Cập nhật lần cuối: 2026-11-23.

## Đã xong, đã push lên `main`

| Commit | Nội dung |
|---|---|
| `f7ff475`, `c677f47` | migrate giữ linuxbrew trên PATH (block trong `env.local`, nối cuối); doctor kiểm tra theo session mới (đọc `PATH=` trong `/etc/environment`) |
| `1075061` | `--keep-linuxbrew` / `--drop-linuxbrew`; report liệt kê các lệnh chỉ có trong brew |
| `b669ea6` | doctor WARN khi zsh khởi động quá 600 ms |
| `fcbf9de` | WSL1: không chạy `mise activate` lúc khởi động và mỗi prompt; dùng cache môi trường mise, vào thư mục có `mise.toml` thì chuyển sang activate bình thường. Gate fzf-tab đọc init cache, không chạy fzf |
| `a91e244` | `source ~/.zshrc` / `~/.bashrc` không lỗi, giữ nguyên chế độ |

Full suite ở `a91e244`: 114 PASS / 0 FAIL.

Máy WSL (laptop) đã cài lại từ GitHub (`DOTFILES_REPO=https://github.com/nguyenleminhquan/dotfiles`), nên `dotfiles update` đã có nguồn.

## Đang làm: branch `bugfix/linear-path-edit`

Đo trên terminal WSL thật sau khi cài `a91e244`: `zsh -i` khoảng **6.0 s** (trước đó khoảng 3.0 s).

- Nguyên nhân: `_df_path_add` (shell/env.sh) xoá một entry khỏi PATH bằng `${x%%":$d:"*}` / `${x#*":$d:"}`, chậm theo bình phương độ dài PATH. WSL nối PATH của Windows vào nên PATH dài khoảng 2.8 KB, 54 entry. WSL1 mode đưa 32 thư mục mise lên đầu PATH, mỗi thư mục chạy một lần xoá: zsh mất 4.9 s, bash 1.7 s.
- Docker test không thấy vì PATH ngắn. Doctor báo 1118 ms vì nó đo session mới với PATH ngắn.
- Cách sửa: sửa PATH theo thời gian tuyến tính (zsh dùng mảng `path`; bash/sh tách bằng IFS), không fork. Thêm test với PATH dài kiểu WSL. Trên WSL, doctor đo cả các entry `/mnt/...` của Windows.
- Quy trình: implementer → review → sửa → full suite → merge `main` → push → `dotfiles update` trên WSL → đo lại. Mục tiêu dưới 600 ms.

## Việc của bạn (không phải repo)

- `~/.localrc` trên WSL gọi `debug_echo` (không tồn tại), nên bash chạy `command_not_found_handle` (python), tốn khoảng 1.4 s mỗi lần mở bash. Định nghĩa hàm đó hoặc bỏ dòng gọi.
- Có thể xoá `~/update-dotfiles.sh` trên node đã migrate.

## Giới hạn đã biết của WSL1 mode

- Ở chế độ cache, `mise shell` / `mise deactivate` chưa dùng được cho tới khi `cd` vào project có config mise.
- Cache không tự làm mới khi đổi biến `MISE_*`, hoặc khi config/installs nằm ngoài `~/.config/mise` và `~/.local/share/mise`. Chạy `dotfiles update` để làm mới.
- Shell non-interactive trên WSL1 dùng version global của tool, không theo `mise.toml` của project (ví dụ cron `cd proj && node`).

## Để sau (chưa duyệt)

GitHub Actions CI, tag release, plugin 5, cùng vài điểm nhỏ còn lại từ review.
