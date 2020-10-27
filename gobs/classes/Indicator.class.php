<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Indicator
{
    /**
     * @var project: Indicator code
     */
    protected $indicator_code;

    /**
     * @var data G-Obs Representation of a indicator
     */
    protected $data;

    /**
     * constructor.
     *
     * @param string $indicator_code: the code of the indicator
     * @param mixed  $project
     */
    public function __construct($indicator_code)
    {
        $this->indicator_code = $indicator_code;


        // Create Gobs projet expected data
        $this->buildGobsIndicator();
    }


    /* Create G-Obs project object from Lizmap project
     *
     *
     */
    private function buildGobsIndicator()
    {

        $sql = "
        WITH decompose_values AS (
            SELECT
                i.*,
                array_position(id_value_code, unnest(id_value_code)) AS value_position
            FROM gobs.indicator AS i
            WHERE id_code = $1
        ),
        ind AS (
            SELECT
            decompose_values.id AS id,
            id_code AS code,
            id_label AS label,
            id_description AS description,
            id_category AS category,
            id_date_format AS date_format,

            -- values
            jsonb_agg(jsonb_build_object(
                'code', id_value_code[value_position],
                'name', id_value_name[value_position],
                'type', id_value_type[value_position],
                'unit', id_value_unit[value_position]
            )) AS values,

            decompose_values.created_at,
            decompose_values.updated_at

            FROM decompose_values
            GROUP BY
            decompose_values.id,
            id_code,
            id_label,
            id_description,
            id_date_format,
            id_value_code,
            id_value_name,
            id_value_type,
            id_value_unit,
            id_category,
            decompose_values.created_at,
            decompose_values.updated_at
            ORDER BY id
        ),
        consolidated AS (
            SELECT ind.*,

            -- documents
            json_agg(
            CASE
                WHEN d.id IS NOT NULL THEN json_build_object(
                    'id', d.id,
                    'indicator', ind.code,
                    'label', d.do_label,
                    'description', d.do_description,
                    'type', d.do_type,
                    'url', d.do_path,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at
                )
                ELSE NULL
            END)  AS documents
            FROM ind
            LEFT JOIN gobs.document AS d
                ON d.fk_id_indicator = ind.id
            GROUP BY
            ind.id,
            ind.code,
            ind.label,
            ind.description,
            ind.date_format,
            ind.values,
            ind.category,
            ind.created_at,
            ind.updated_at

        ),
        last AS (
            SELECT
                id, code, label, description, category, date_format,
                values, documents,
                'avatar' AS avatar,
                'blue' AS color,
                created_at,
                updated_at
            FROM consolidated
        )
        SELECT
            row_to_json(last.*) AS indicator_json
        FROM last
        ";
        $gobs_profile = 'gobs';
        $cnx = jDb::getConnection($gobs_profile);
        $stmt = $cnx->prepare($sql);

        $resultset = $cnx->prepare($sql);
        $resultset->execute(array($this->indicator_code));
        $json = null;
        foreach ($resultset->fetchAll() as $record) {
            $json = $record->indicator_json;
        }

        $this->data = json_decode($json);
    }

    // Get Gobs representation of a indicator object
    public function get()
    {
        return $this->data;
    }

}
