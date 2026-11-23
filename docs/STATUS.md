# Status (tạm thời)

File ghi tình hình làm việc, sẽ xoá khi xong đợt này. Cập nhật lần cuối: 2026-11-23 (chiều).

## Đã xong, đã push lên `main`

| Commit | Nội dung |
|---|---|
| `f7ff475`, `c677f47` | migrate giữ linuxbrew trên PATH (block trong `env.local`, nối cuối); doctor kiểm tra theo session mới (đọc `PATH=` trong `/etc/environment`) |
| `1075061` | `--keep-linuxbrew` / `--drop-linuxbrew`; report liệt kê các lệnh chỉ có trong brew |
| `b669ea6` | doctor WARN khi zsh khởi động quá 600 ms |
| `fcbf9de` | WSL1: không chạy `mise activate` lúc khởi động và mỗi prompt; dùng cache môi trường mise, vào thư mục có `mise.toml` thì chuyển sang activate bình thường. Gate fzf-tab đọc init cache, không chạy fzf |
| `a91e244` | `source ~/.zshrc` / `~/.bashrc` không lỗi, giữ nguyên chế độ |
| `b3a9631` | sửa PATH theo thời gian tuyến tính (trước đó chậm theo bình phương độ dài PATH, mất vài giây trên PATH dài của WSL) |
| `c1266f0` | trên WSL, doctor đo thời gian khởi động với PATH có các entry Windows `/mnt/...` |
| `0ba8740` | `_df_wsl_filter` tách PATH tuyến tính; test đo khởi động với filter bật |
| `9edb830` | `dotfiles update` chạy installer từ bản copy trong `~/.cache/dotfiles` (WSL1 không cho đổi tên thư mục đang có file mở); báo lỗi rõ khi đổi tên `~/.dotfiles` thất bại |

Full suite ở `0ba8740` và ở `9edb830`: 114 PASS / 0 FAIL. Mỗi task đều qua review và một vòng sửa.

## Kết quả đo trên WSL1 (laptop, terminal mới, PATH Windows 2.9 KB)

Đã trừ overhead của `script` (pty) trên WSL1, khoảng 730–750 ms tuỳ lúc.

| | Trước đợt sửa (`1075061`) | `a91e244` | Giờ (`9edb830`) |
|---|---|---|---|
| `zsh -i` | khoảng 2.3 s | khoảng 5.5 s (lỗi PATH chậm theo bình phương) | **khoảng 650–700 ms** |
| Số lần gọi mise mỗi lần mở shell / mỗi prompt | 2+ | 0 | 0 |
| doctor `zsh startup` | — | 1118 ms | 693 ms (WARN, budget 600 ms) |

Trong khoảng 650 ms còn lại, khoảng 100 ms là `~/.localrc` của bạn. Phần còn lại là compinit, starship, zoxide, fzf (đều đọc từ cache) và chi phí spawn process của WSL1. WSL2 mới giải quyết được triệt để.

`bash -i` khoảng 1.6 s, trong đó 1.4 s do `~/.localrc` (xem mục dưới).

## `dotfiles update` trên WSL1: đã sửa và đã thử thật

- Lỗi cũ: `mv: cannot move ~/.dotfiles ... Permission denied` (bash giữ install.sh mở trong lúc đổi tên `~/.dotfiles`).
- Đã thử trên laptop ở `9edb830`: `dotfiles update` exit 0, không còn bản copy hay `~/.dotfiles.old.*` nào sót lại.
- Máy nào còn bản cũ hơn `9edb830` thì lần update đầu tiên vẫn lỗi như trên (vì `bin/dotfiles` cũ vẫn chạy installer ngay trong `~/.dotfiles`). Lần đó cài lại một lần bằng installer tải về:
  `curl -fsSL https://raw.githubusercontent.com/nguyenleminhquan/dotfiles/main/install.sh -o ~/.cache/df-install.sh && DOTFILES_REPO=https://github.com/nguyenleminhquan/dotfiles bash ~/.cache/df-install.sh; rm -f ~/.cache/df-install.sh`.
  Từ lần sau `dotfiles update` chạy bình thường.
- Còn lại (chưa làm): `dotfiles uninstall --purge` cũng xoá `~/.dotfiles` trong lúc đang chạy script nằm trong đó, có thể gặp cùng lỗi trên WSL1. Chưa kiểm chứng.

## Việc của bạn (không phải repo)

- `~/.localrc` trên WSL gọi `debug_echo` (không tồn tại), nên bash chạy `command_not_found_handle` (python), tốn khoảng 1.4 s mỗi lần mở bash. Định nghĩa hàm đó hoặc bỏ dòng gọi.
- Có thể xoá `~/update-dotfiles.sh` trên node đã migrate.
- Cân nhắc chuyển máy này sang WSL2 (spawn process native, mise activate chỉ khoảng 10 ms).

## Giới hạn đã biết của WSL1 mode

- Ở chế độ cache, `mise shell` / `mise deactivate` chưa dùng được cho tới khi `cd` vào project có config mise.
- Cache không tự làm mới khi đổi biến `MISE_*`, hoặc khi config/installs nằm ngoài `~/.config/mise` và `~/.local/share/mise`. Chạy `dotfiles update` để làm mới.
- Shell non-interactive trên WSL1 dùng version global của tool, không theo `mise.toml` của project (ví dụ cron `cd proj && node`).

## Để sau (chưa duyệt)

GitHub Actions CI, tag release, plugin 5, cùng vài điểm nhỏ còn lại từ review (ghi trong ledger local).
