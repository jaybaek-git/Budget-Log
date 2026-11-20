# 가계부(Budget-Log) 인수인계 메모

> 새 대화에서: "jaybaek-git/Budget-Log 의 HANDOFF.md 먼저 읽고 시작해 줘"
> 마지막 버전: **v1.1** (2026-11-20) — Baby-Log 구조를 그대로 따라 만듦

## 1. 무엇
- 부부 공유 가계부 웹앱 (PWA). https://jaybaek-git.github.io/Budget-Log/ (GitHub Pages, `main` 루트)
- 지출/수입 기록, 월 예산(전체+카테고리), 고정지출 자동 기록, 상대방 기록·예산 알림
- 구분: 하나의 가계부로 합산, 기록한 사람(`created_by`)만 표시

## 2. 작업 방식 (사용자 선호)
- 작은 수정은 v1.0.1, v1.0.2 …, 큰 기능은 v1.1
- 매 버전: `releases/Budget-Log_vX.zip` + `index.html`의 `APP_VERSION` + 커밋/푸시
- 더 좋은 방안이 있으면 선택지로 먼저 묻기 / UI 변경은 목업 먼저 요청할 때가 많음
- Supabase SQL은 Claude가 MCP로 직접 적용 → `supabase_vX_*.sql`로 저장소에도 남김
- 한국어, 모바일이라 짧게

## 3. 구조
### 프런트 (`index.html` 한 파일, 바닐라 JS)
- `h()` DOM 헬퍼, 차트는 SVG 문자열
- 폰별(localStorage): `bg_dev`(url/key/code/who), `bg_theme`, `bg_tab`, `bg_cache`, 로컬 모드 기록 `bg_tx`
- 공통(서버 `app_config.data`): `title`, `catVer`(2), `cats[]`(id, emoji, name, color, kind=out/in, budget, hidden, **subs[]** 세부 항목), `budget{total, alert}`, `liveNotify`
- 주요 함수: `refresh`, `renderSum`, `renderCats`, `renderList/Stats/Cal/Settings`, `openTx`(입력·수정), `openFixed`, `amountPad`(숫자패드), `openDay`
- 데이터는 보고 있는 달 기준 6개월치(`list_tx`)를 한 번에 불러옴
- 연결 코드 형식: `BUDGETLOG|url|key|code|who`

### 서버 (Supabase 프로젝트 `brnjahsragazesuqxtrd`, 이름 "jaybaek-git's Project", 도쿄)
- 무료 플랜 활성 프로젝트 2개 제한 → Baby-Log와 이 프로젝트 2개 사용 중
- 테이블: `tx`(kind, amount, cat, **sub**, at, memo, created_by, fixed_id), `fixed`(day, last_month …), `app_config`, `app_secret`(가족 코드·VAPID), `app_state`(edge_url, 예산 알림 단계), `push_subs`, `push_queue`
- RLS 켜고 직접 접근 막음 → `SECURITY DEFINER` RPC + `_chk(가족코드)`
- RPC: add_tx, update_tx, delete_tx, list_tx, import_tx, get_config, set_config, list_fixed, save_fixed, delete_fixed, save_push_sub, delete_push_sub, get_vapid_public, test_push
- 트리거 `_tx_notify`: 이번 달 기록이면 상대방 알림(본인 제외) + 예산 80/100% 알림(달마다 1번씩)
- pg_cron `budget-log-fixed`: 매일 00:05 KST `_run_fixed()` (저장 직후에도 실행). 새 항목 날짜가 이미 지났으면 다음 달부터
- 알림: `_push()` → push_queue → pg_net → Edge Function `push` (verify_jwt=false)

## 4. 함정 (Baby-Log와 같음)
- iOS 홈 화면 앱 키보드 안 뜸 → 숫자는 화면 숫자패드, 글자는 `prompt()`
- 웹 푸시는 홈 화면 앱에서만 (iOS 16.4+)
- Pages 반영 몇 분 + 홈 화면 앱 완전 종료 후 재실행, 설정 맨 아래 버전 확인
- 가족 코드·키는 저장소에 올리지 않음 (공개 저장소)

## 5. 앞으로 아이디어
- 카드 문자/알림 → 단축어로 자동 기록, Siri 음성 기록("커피 4500")
- 할부, 월 시작일(월급날 기준) 설정, 연간 통계

## 6. 버전 기록
- v1.0 (11/19) 첫 버전 / v1.0.1 화면 오류 표시
- v1.1 (11/20) 사용자가 쓰던 가계부 앱 기준 카테고리 21개(카드대금·잔액조정 제외, 저축·대출은 지출로) + 세부 항목(선택), 첫 화면 5열로 전부 표시, 통계에서 카테고리 누르면 세부별 펼침, 카테고리 편집 시트 — SQL `supabase_v1.1_subcat.sql`

## 7. 카드 명세서로 기록하기 (Claude가 대신 입력)
- 사용자가 명세서 PDF·스크린샷을 보내면 Claude가 읽어 `import_tx`(알림 없음)로 넣음. 기록자 `삼성카드`
- '입금(취소), 포인트납부금액'은 **선결제** → 실제 지출로 기록. 회원할인으로 0원·취소 건은 제외. 할부는 이번 달 납부액만(메모에 회차)
- 모르는 항목은 추측해서 넣지 말고 **추측안을 선택지로 바로 물어보기** (사용자 요청)
- 11월 삼성카드분 입력 완료 (삼성전자 3건은 친구 물건이라 삭제). 네이버페이·쿠팡 건별 카테고리는 확인 대기
