/**
 * 一份**完全编造**的教务处课表 XML 片段，用来在电脑上验证 XlsxService。
 *
 * 为什么是片段而不是真的 .xlsx：自测跑在 Node 里、不需要解压能力，
 * 而 XlsxService 的输入本来就是「解压后的 XML」，直接喂 XML 反而更贴近它的契约。
 *
 * 形状照着真实的教务处「各校区课表」抄（列布局、块头写法、一格多课的分隔线、
 * 「十一节」这种省略「第」字的写法），但**所有课名、教师、班号、学院都是虚构的**。
 */

/** 共享字符串表。索引必须和下面的单元格里写的数字一一对应 */
export const XLSX_SHARED_XML: string = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="39" uniqueCount="39"><si><t>z000001</t></si><si><t>示例学院</t></si><si><t>25级</t></si><si><t>示 例 大 学 课 程 表</t></si><si><t>小班代号：z000001</t></si><si><t>辅导员：示例老师甲</t></si><si><t>人数：30</t></si><si><t>校区：示例校区</t></si><si><t>专业名称：示例工程</t></si><si><t>课程名称</t></si><si><t>总学时</t></si><si><t>上课周数(  周至  周)</t></si><si><t>讲课教师</t></si><si><t>示例课程甲</t></si><si><t>1-16</t></si><si><t>示例教师甲</t></si><si><t>示例课程乙</t></si><si><t>13-16</t></si><si><t>示例教师乙</t></si><si><t>星期一</t></si><si><t>星期二</t></si><si><t>星期三</t></si><si><t>星期四</t></si><si><t>星期五</t></si><si><t>第一节</t></si><si><t>第二节</t></si><si><t>第三节</t></si><si><t>第四节</t></si><si><t>第五节</t></si><si><t>第六节</t></si><si><t>示例课程甲 &#10;1-16&#10;-----------&#10;示例课程乙 &#10;13-16</t></si><si><t>&#10;101 &#10;-----------&#10;&#10;202 </t></si><si><t>示例课程乙 &#10;13-16</t></si><si><t>&#10;202 </t></si><si><t>通识教育选修课</t></si><si><t>注意：本表信息仅供参考，以教务系统为准</t></si><si><t>中午1</t></si><si><t>傍晚</t></si><si><t>十一节</t></si><si><t>&#10;101 </t></si></sst>`;

/** 一个「小班」块。行 1-3 是块头，4-5 是课程清单，7 是星期表头，8 起是节次行 */
export const XLSX_SHEET_XML: string = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1" spans="1:16"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>0</v></c><c r="C1" t="s"><v>3</v></c><c r="F1" t="s"><v>4</v></c><c r="H1" t="s"><v>5</v></c><c r="K1" t="s"><v>6</v></c><c r="M1" t="s"><v>7</v></c><c r="O1" t="s"><v>1</v></c><c r="P1" t="s"><v>2</v></c></row>
<row r="2" spans="1:16"><c r="A2" t="s"><v>0</v></c><c r="B2" t="s"><v>0</v></c><c r="C2" t="s"><v>8</v></c><c r="F2" t="s"><v>4</v></c><c r="O2" t="s"><v>1</v></c><c r="P2" t="s"><v>2</v></c></row>
<row r="3" spans="1:16"><c r="A3" t="s"><v>0</v></c><c r="B3" t="s"><v>0</v></c><c r="C3" t="s"><v>9</v></c><c r="E3" t="s"><v>10</v></c><c r="I3" t="s"><v>11</v></c><c r="K3" t="s"><v>12</v></c><c r="O3" t="s"><v>1</v></c><c r="P3" t="s"><v>2</v></c></row>
<row r="4" spans="1:16"><c r="A4" t="s"><v>0</v></c><c r="B4" t="s"><v>0</v></c><c r="C4" t="s"><v>13</v></c><c r="I4" t="s"><v>14</v></c><c r="K4" t="s"><v>15</v></c><c r="O4" t="s"><v>1</v></c><c r="P4" t="s"><v>2</v></c></row>
<row r="5" spans="1:16"><c r="A5" t="s"><v>0</v></c><c r="B5" t="s"><v>0</v></c><c r="C5" t="s"><v>16</v></c><c r="I5" t="s"><v>17</v></c><c r="K5" t="s"><v>18</v></c><c r="O5" t="s"><v>1</v></c><c r="P5" t="s"><v>2</v></c></row>
<row r="6" spans="1:16"><c r="A6" t="s"><v>0</v></c><c r="B6" t="s"><v>0</v></c><c r="C6" t="s"><v>35</v></c><c r="O6" t="s"><v>1</v></c><c r="P6" t="s"><v>2</v></c></row>
<row r="7" spans="1:16"><c r="A7" t="s"><v>0</v></c><c r="B7" t="s"><v>0</v></c><c r="D7"/><c r="E7" t="s"><v>19</v></c><c r="G7" t="s"><v>20</v></c><c r="I7" t="s"><v>21</v></c><c r="K7" t="s"><v>22</v></c><c r="M7" t="s"><v>23</v></c><c r="O7" t="s"><v>1</v></c><c r="P7" t="s"><v>2</v></c></row>
<row r="8" spans="1:16"><c r="A8" t="s"><v>0</v></c><c r="B8" t="s"><v>0</v></c><c r="C8" t="s"><v>24</v></c><c r="E8" t="s"><v>30</v></c><c r="F8" t="s"><v>31</v></c><c r="O8" t="s"><v>1</v></c><c r="P8" t="s"><v>2</v></c></row>
<row r="9" spans="1:16"><c r="A9" t="s"><v>0</v></c><c r="B9" t="s"><v>0</v></c><c r="C9" t="s"><v>25</v></c><c r="O9" t="s"><v>1</v></c><c r="P9" t="s"><v>2</v></c></row>
<row r="10" spans="1:16"><c r="A10" t="s"><v>0</v></c><c r="B10" t="s"><v>0</v></c><c r="C10" t="s"><v>26</v></c><c r="I10" t="s"><v>32</v></c><c r="J10" t="s"><v>33</v></c><c r="K10" t="s"><v>34</v></c><c r="O10" t="s"><v>1</v></c><c r="P10" t="s"><v>2</v></c></row>
<row r="11" spans="1:16"><c r="A11" t="s"><v>0</v></c><c r="B11" t="s"><v>0</v></c><c r="C11" t="s"><v>27</v></c><c r="O11" t="s"><v>1</v></c><c r="P11" t="s"><v>2</v></c></row>
<row r="12" spans="1:16"><c r="A12" t="s"><v>0</v></c><c r="B12" t="s"><v>0</v></c><c r="C12" t="s"><v>28</v></c><c r="O12" t="s"><v>1</v></c><c r="P12" t="s"><v>2</v></c></row>
<row r="13" spans="1:16"><c r="A13" t="s"><v>0</v></c><c r="B13" t="s"><v>0</v></c><c r="C13" t="s"><v>29</v></c><c r="O13" t="s"><v>1</v></c><c r="P13" t="s"><v>2</v></c></row>
<row r="14" spans="1:16"><c r="A14" t="s"><v>0</v></c><c r="B14" t="s"><v>0</v></c><c r="C14" t="s"><v>36</v></c><c r="O14" t="s"><v>1</v></c><c r="P14" t="s"><v>2</v></c></row>
<row r="15" spans="1:16"><c r="A15" t="s"><v>0</v></c><c r="B15" t="s"><v>0</v></c><c r="C15" t="s"><v>37</v></c><c r="O15" t="s"><v>1</v></c><c r="P15" t="s"><v>2</v></c></row>
<row r="16" spans="1:16"><c r="A16" t="s"><v>0</v></c><c r="B16" t="s"><v>0</v></c><c r="C16" t="s"><v>38</v></c><c r="E16" t="s"><v>13</v></c><c r="F16" t="s"><v>39</v></c><c r="O16" t="s"><v>1</v></c><c r="P16" t="s"><v>2</v></c></row>
</sheetData></worksheet>`;

/** 第二个 sheet，用来验证「多个 sheet 都要扫」和 sheet→路径 的映射 */
export const XLSX_WORKBOOK_XML: string = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="示例学院" sheetId="1" r:id="rId1"/><sheet name="另一个学院" sheetId="2" r:id="rId2"/></sheets></workbook>`;

export const XLSX_RELS_XML: string = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>`;
